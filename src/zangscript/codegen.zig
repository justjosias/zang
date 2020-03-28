const std = @import("std");
const Source = @import("common.zig").Source;
const fail = @import("common.zig").fail;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const Expression = @import("second_pass.zig").Expression;
const getExpressionType = @import("second_pass.zig").getExpressionType;
const builtins = @import("builtins.zig").builtins;

// TODO i'm tending towards the idea of this file not even being involved at all
// in runtime script mode.
// so type checking and everything like that should be moved all into second_pass.
// this file will be very specific for generating zig code, i think.
// although, i'm not sure. temp floats are not needed for runtime script mode,
// but temps (temp buffers) are? (although i could just allocate those dynamically
// as well since i don't have a lot of performance requirements for script mode.)

// FIXME - tag type should be datatype? (constant, boolean, constant_or_buffer)
pub const InstrCallArg = union(enum) {
    temp: usize,
    temp_float: usize,
    temp_bool: usize,
};

pub const InstrCall = struct {
    result_loc: ResultLoc,
    field_index: usize,
    // list of temp indices for the callee's internal use
    temps: std.ArrayList(usize),
    // in the order of the callee module's params
    args: []InstrCallArg,
};

pub const BufferLoc = union(enum) {
    temp: usize,
    output: usize,
};

pub const ResultLoc = union(enum) {
    buffer: BufferLoc,
    temp_float: usize,
    temp_bool: usize,
};

pub const InstrLoadBoolean = struct {
    out_index: usize,
    value: bool,
};

pub const InstrLoadConstant = struct {
    out_index: usize,
    value: f32,
};

pub const InstrFloatToBuffer = struct {
    out: BufferLoc,
    in_temp_float: usize,
};

pub const InstrLoadParamFloat = struct {
    out_temp_float: usize,
    param_index: usize,
};

pub const InstrArithFloatFloat = struct {
    operator: enum { add, multiply },
    out_temp_float: usize,
    a_temp_float: usize,
    b_temp_float: usize,
};

pub const InstrArithBufferFloat = struct {
    operator: enum { add, multiply },
    out: BufferLoc,
    temp_index: usize,
    temp_float_index: usize,
};

pub const Instruction = union(enum) {
    call: InstrCall,
    float_to_buffer: InstrFloatToBuffer,
    load_param_float: InstrLoadParamFloat,
    load_boolean: InstrLoadBoolean,
    load_constant: InstrLoadConstant,
    arith_float_float: InstrArithFloatFloat,
    arith_buffer_float: InstrArithBufferFloat,
};

const CodegenState = struct {
    allocator: *std.mem.Allocator,
    source: Source,
    first_pass_result: FirstPassResult,
    code_gen_results: []const CodeGenResult,
    module_index: usize,
    instructions: std.ArrayList(Instruction),
    num_temps: usize,
    num_temp_floats: usize,
    num_temp_bools: usize,
};

pub const GenError = error{
    Failed,
    OutOfMemory,
};

fn genExpression(self: *CodegenState, result_loc: ResultLoc, expression: *const Expression) GenError!void {
    const module = self.first_pass_result.modules[self.module_index];
    const self_params = self.first_pass_result.module_params[module.first_param .. module.first_param + module.num_params];

    switch (expression.inner) {
        .call => |call| {
            const field = self.first_pass_result.module_fields[module.first_field + call.field_index];
            // FIXME make sure the callee module has already been codegen'd! that's where its num_temps actually gets filled in
            const callee_num_temps = self.code_gen_results[field.resolved_module_index].num_temps;
            const callee_params = blk: {
                const callee_module = self.first_pass_result.modules[field.resolved_module_index];
                break :blk self.first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];
            };

            var icall: InstrCall = .{
                .result_loc = result_loc,
                .field_index = call.field_index,
                .temps = std.ArrayList(usize).init(self.allocator),
                .args = try self.allocator.alloc(InstrCallArg, callee_params.len),
            };
            // TODO deinit

            // the callee needs temps for its own internal use
            var i: usize = 0;
            while (i < callee_num_temps) : (i += 1) {
                try icall.temps.append(self.num_temps);
                self.num_temps += 1;
            }

            // pass params
            for (callee_params) |param, j| {
                // find this arg in the call node. (not necessarily in the same order.)
                const arg = blk: {
                    for (call.args.span()) |a| {
                        if (std.mem.eql(u8, a.arg_name, param.name)) {
                            break :blk a;
                        }
                    }
                    // missing args was already checked in second_pass
                    unreachable;
                };

                // allocate a temporary to store subexpression result
                switch (param.param_type) {
                    .constant_or_buffer => {
                        const out_index = self.num_temps;
                        self.num_temps += 1;
                        try genExpression(self, .{ .buffer = .{ .temp = out_index } }, arg.value);

                        icall.args[j] = .{ .temp = out_index };
                    },
                    .constant => {
                        const out_index = self.num_temp_floats;
                        self.num_temp_floats += 1;
                        try genExpression(self, .{ .temp_float = out_index }, arg.value);

                        icall.args[j] = .{ .temp_float = out_index };
                    },
                    .boolean => {
                        const out_index = self.num_temp_bools;
                        self.num_temp_bools += 1;
                        try genExpression(self, .{ .temp_bool = out_index }, arg.value);

                        icall.args[j] = .{ .temp_bool = out_index };
                    },
                    else => unreachable,
                }
            }

            try self.instructions.append(.{ .call = icall });
        },
        .literal => |literal| {
            switch (result_loc) {
                .buffer => |buffer_loc| {
                    const temp_float_index = self.num_temp_floats;
                    self.num_temp_floats += 1;
                    try self.instructions.append(.{
                        .load_constant = .{
                            .out_index = temp_float_index,
                            .value = switch (literal) {
                                .constant => |v| v,
                                else => unreachable,
                            },
                        },
                    });
                    try self.instructions.append(.{
                        .float_to_buffer = .{
                            .out = buffer_loc,
                            .in_temp_float = temp_float_index,
                        },
                    });
                },
                .temp_float => |index| {
                    try self.instructions.append(.{
                        .load_constant = .{
                            .out_index = index,
                            .value = switch (literal) {
                                .constant => |v| v,
                                else => unreachable,
                            },
                        },
                    });
                },
                .temp_bool => |index| {
                    try self.instructions.append(.{
                        .load_boolean = .{
                            .out_index = index,
                            .value = switch (literal) {
                                .boolean => |v| v,
                                else => unreachable,
                            },
                        },
                    });
                },
            }
        },
        .self_param => |param_index| {
            const param = self_params[param_index];
            switch (result_loc) {
                .buffer => |buffer_loc| {
                    // result is a buffer. what is the param type?
                    switch (param.param_type) {
                        .constant => {
                            const temp_float_index = self.num_temp_floats;
                            self.num_temp_floats += 1;
                            try self.instructions.append(.{
                                .load_param_float = .{
                                    .out_temp_float = temp_float_index,
                                    .param_index = param_index,
                                },
                            });
                            try self.instructions.append(.{
                                .float_to_buffer = .{
                                    .out = buffer_loc,
                                    .in_temp_float = temp_float_index,
                                },
                            });
                        },
                        else => unreachable,
                    }
                },
                .temp_float => |index| {
                    // result is a float. what is the param type?
                    switch (param.param_type) {
                        .constant => {
                            try self.instructions.append(.{
                                .load_param_float = .{
                                    .out_temp_float = index,
                                    .param_index = param_index,
                                },
                            });
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        },
        .binary_arithmetic => |m| {
            // no type checking has been performed yet...
            // (not true?)
            const a_type = try getExpressionType(self.source, self_params, m.a);
            const b_type = try getExpressionType(self.source, self_params, m.b);

            switch (result_loc) {
                .temp_bool => {
                    unreachable;
                },
                .temp_float => |out_temp_float| {
                    // float = float + float
                    if (a_type != .constant or b_type != .constant) {
                        return fail(self.source, expression.source_range, "dest is float, so operands must both be floats", .{});
                    }

                    const out_index_a = self.num_temp_floats;
                    self.num_temp_floats += 1;
                    try genExpression(self, .{ .temp_float = out_index_a }, m.a);

                    const out_index_b = self.num_temp_floats;
                    self.num_temp_floats += 1;
                    try genExpression(self, .{ .temp_float = out_index_b }, m.b);

                    try self.instructions.append(.{
                        .arith_float_float = .{
                            .operator = switch (m.operator) {
                                .add => .add,
                                .multiply => .multiply,
                            },
                            .out_temp_float = out_temp_float,
                            .a_temp_float = out_index_a,
                            .b_temp_float = out_index_b,
                        },
                    });
                },
                .buffer => |buffer_loc| {
                    // FIXME constant_or_buffer makes no sense here!
                    if (a_type == .constant_or_buffer and b_type == .constant) {
                        const out_index_a = self.num_temps;
                        self.num_temps += 1;
                        try genExpression(self, .{ .buffer = .{ .temp = out_index_a } }, m.a);

                        const out_index_b = self.num_temp_floats;
                        self.num_temp_floats += 1;
                        try genExpression(self, .{ .temp_float = out_index_b }, m.b);

                        try self.instructions.append(.{
                            .arith_buffer_float = .{
                                .operator = switch (m.operator) {
                                    .add => .add,
                                    .multiply => .multiply,
                                },
                                .out = buffer_loc,
                                .temp_index = out_index_a,
                                .temp_float_index = out_index_b,
                            },
                        });
                    } else if (a_type == .constant and b_type == .constant_or_buffer) {
                        const out_index_a = self.num_temp_floats;
                        self.num_temp_floats += 1;
                        try genExpression(self, .{ .temp_float = out_index_a }, m.a);

                        const out_index_b = self.num_temps;
                        self.num_temps += 1;
                        try genExpression(self, .{ .buffer = .{ .temp = out_index_b } }, m.b);

                        try self.instructions.append(.{
                            .arith_buffer_float = .{
                                .operator = switch (m.operator) {
                                    .add => .add,
                                    .multiply => .multiply,
                                },
                                .out = buffer_loc,
                                .temp_index = out_index_a,
                                .temp_float_index = out_index_b,
                            },
                        });
                    } else if (a_type == .constant and b_type == .constant) {
                        const out_temp_float = self.num_temp_floats;
                        self.num_temp_floats += 1;

                        const out_index_a = self.num_temp_floats;
                        self.num_temp_floats += 1;
                        try genExpression(self, .{ .temp_float = out_index_a }, m.a);

                        const out_index_b = self.num_temp_floats;
                        self.num_temp_floats += 1;
                        try genExpression(self, .{ .temp_float = out_index_b }, m.b);

                        try self.instructions.append(.{
                            .arith_float_float = .{
                                .operator = switch (m.operator) {
                                    .add => .add,
                                    .multiply => .multiply,
                                },
                                .out_temp_float = out_temp_float,
                                .a_temp_float = out_index_a,
                                .b_temp_float = out_index_b,
                            },
                        });
                        try self.instructions.append(.{
                            .float_to_buffer = .{
                                .out = buffer_loc,
                                .in_temp_float = out_temp_float,
                            },
                        });
                    } else {
                        return fail(self.source, expression.source_range, "dest is buffer, unsupported operand types", .{});
                    }
                },
            }
        },
        .nothing => {},
    }
}

pub const CodeGenResult = struct {
    num_outputs: usize,
    num_temps: usize,
    instructions: []const Instruction,
};

// code_gen_results is just there so we can read the num_temps of modules being called.
pub fn codegen(source: Source, code_gen_results: []const CodeGenResult, first_pass_result: FirstPassResult, module_index: usize, expression: *const Expression, allocator: *std.mem.Allocator) !CodeGenResult {
    var self: CodegenState = .{
        .allocator = allocator,
        .source = source,
        .first_pass_result = first_pass_result,
        .code_gen_results = code_gen_results,
        .module_index = module_index,
        .instructions = std.ArrayList(Instruction).init(allocator),
        .num_temps = 0,
        .num_temp_floats = 0,
        .num_temp_bools = 0,
    };
    // TODO deinit

    try genExpression(&self, .{ .buffer = .{ .output = 0 } }, expression);

    std.debug.warn("num_temps: {}\n", .{self.num_temps});
    std.debug.warn("num_temp_floats: {}\n", .{self.num_temp_floats});
    std.debug.warn("num_temp_bools: {}\n", .{self.num_temp_bools});
    printBytecode(&self);
    std.debug.warn("\n", .{});

    return CodeGenResult{
        .num_outputs = 1,
        .num_temps = self.num_temps,
        .instructions = self.instructions.span(),
    };
}

pub fn printBytecode(self: *CodegenState) void {
    const self_module = self.first_pass_result.modules[self.module_index];
    const instructions = self.instructions.span();
    std.debug.warn("bytecode:\n", .{});
    for (instructions) |instr| {
        std.debug.warn("    ", .{});
        switch (instr) {
            .call => |call| {
                switch (call.result_loc) {
                    .buffer => |buffer_loc| {
                        switch (buffer_loc) {
                            .output => |n| std.debug.warn("output{}", .{n}),
                            .temp => |n| std.debug.warn("temp{}", .{n}),
                        }
                    },
                    .temp_float => |n| std.debug.warn("temp_float{}", .{n}),
                    .temp_bool => |n| std.debug.warn("temp_bool{}", .{n}),
                }
                const field = self.first_pass_result.module_fields[self_module.first_field + call.field_index];
                const callee_module_name = self.first_pass_result.modules[field.resolved_module_index].name;
                const callee_params = blk: {
                    const callee_module = self.first_pass_result.modules[field.resolved_module_index];
                    break :blk self.first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];
                };
                std.debug.warn(" = CALL #{}({}: {})\n", .{ call.field_index, field.name, callee_module_name });
                std.debug.warn("        temps: [", .{});
                for (call.temps.span()) |temp, i| {
                    if (i > 0) std.debug.warn(", ", .{});
                    std.debug.warn("temp{}", .{temp});
                }
                std.debug.warn("]\n", .{});
                for (call.args) |arg, i| {
                    std.debug.warn("        {} = ", .{callee_params[i].name});
                    switch (arg) {
                        .temp => |v| {
                            std.debug.warn("temp{}\n", .{v});
                        },
                        .temp_float => |n| {
                            std.debug.warn("temp_float{}\n", .{n});
                        },
                        .temp_bool => |n| {
                            std.debug.warn("temp_bool{}\n", .{n});
                        },
                    }
                }
            },
            .load_constant => |x| {
                std.debug.warn("temp_float{} = LOADCONSTANT {d}\n", .{ x.out_index, x.value });
            },
            .load_boolean => |x| {
                std.debug.warn("temp_bool{} = LOADBOOLEAN {}\n", .{ x.out_index, x.value });
            },
            .float_to_buffer => |x| {
                switch (x.out) {
                    .temp => |n| std.debug.warn("temp{}", .{n}),
                    .output => |n| std.debug.warn("output{}", .{n}),
                }
                std.debug.warn(" = FLOAT_TO_BUFFER temp_float{}\n", .{x.in_temp_float});
            },
            .load_param_float => |x| {
                std.debug.warn("temp_float{} = LOADPARAM_FLOAT ${}({})\n", .{
                    x.out_temp_float,
                    x.param_index,
                    self.first_pass_result.module_params[self_module.first_param + x.param_index].name,
                });
            },
            .arith_float_float => |x| {
                std.debug.warn("temp_float{} = ARITH_FLOAT_FLOAT {} temp_float{} temp_float{}\n", .{
                    x.operator,
                    x.out_temp_float,
                    x.a_temp_float,
                    x.b_temp_float,
                });
            },
            .arith_buffer_float => |x| {
                switch (x.out) {
                    .temp => |n| std.debug.warn("temp{}", .{n}),
                    .output => |n| std.debug.warn("output{}", .{n}),
                }
                std.debug.warn(" = ARITH_BUFFER_FLOAT {} temp{} temp_float{}\n", .{
                    x.operator,
                    x.temp_index,
                    x.temp_float_index,
                });
            },
        }
    }
}
