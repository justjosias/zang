const std = @import("std");
const Source = @import("common.zig").Source;
const SourceRange = @import("common.zig").SourceRange;
const fail = @import("common.zig").fail;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const ModuleParam = @import("first_pass.zig").ModuleParam;
const ParamType = @import("first_pass.zig").ParamType;
const BinArithOp = @import("second_pass.zig").BinArithOp;
const Expression = @import("second_pass.zig").Expression;
const Literal = @import("second_pass.zig").Literal;
const builtins = @import("builtins.zig").builtins;
const printBytecode = @import("codegen_print.zig").printBytecode;

// a goal of this pass is to catch all errors that would cause the zig code to fail.
// in other words, codegen_zig should never generate zig code that fails to compile

// TODO i'm tending towards the idea of this file not even being involved at all
// in runtime script mode.
// so type checking and everything like that should be moved all into second_pass.
// this file will be very specific for generating zig code, i think.
// although, i'm not sure. temp floats are not needed for runtime script mode,
// but temps (temp buffers) are? (although i could just allocate those dynamically
// as well since i don't have a lot of performance requirements for script mode.)

// expression will return how it stored its result.
pub const ExpressionResult = union(enum) {
    temp_buffer: usize,
    temp_float: usize,
    temp_bool: usize,
    literal: Literal,
    self_param: usize,
};

// call one of self's fields (paint the child module)
pub const InstrCall = struct {
    // paint always results in a buffer.
    out_temp_buffer_index: usize,
    // which field of the "self" module we are calling
    field_index: usize,
    // list of temp buffers passed along for the callee's internal use, dependency injection style
    temps: std.ArrayList(usize),
    // list of argument param values (in the order of the callee module's params)
    args: []ExpressionResult,
};

pub const FloatValue = union(enum) {
    temp_float_index: usize,
    self_param: usize, // guaranteed to be of type `constant`
    literal: f32,
};

pub const InstrFloatToBuffer = struct {
    out_temp_buffer_index: usize,
    in: FloatValue,
};

pub const InstrArithFloatFloat = struct {
    operator: BinArithOp,
    out_temp_float_index: usize,
    a: FloatValue,
    b: FloatValue,
};

// for these, we don't generate a "float_to_buffer" because some of the builtin
// arithmetic functions support buffer*float
pub const InstrArithBufferFloat = struct {
    operator: BinArithOp,
    out_temp_buffer_index: usize,
    a: BufferValue,
    b: FloatValue,
};

pub const BufferValue = union(enum) {
    temp_buffer_index: usize,
    self_param: usize, // guaranteed to be of type `buffer`
};

pub const InstrArithBufferBuffer = struct {
    operator: BinArithOp,
    out_temp_buffer_index: usize,
    a: BufferValue,
    b: BufferValue,
};

pub const InstrOutput = struct {
    value: BufferValue,
};

pub const Instruction = union(enum) {
    float_to_buffer: InstrFloatToBuffer,
    arith_float_float: InstrArithFloatFloat,
    arith_buffer_float: InstrArithBufferFloat,
    arith_buffer_buffer: InstrArithBufferBuffer,
    call: InstrCall,
    output: InstrOutput,
};

pub const CodegenState = struct {
    allocator: *std.mem.Allocator,
    source: Source,
    first_pass_result: FirstPassResult,
    codegen_results: []const CodeGenResult,
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

fn getFloatValue(self: *CodegenState, result: ExpressionResult) ?FloatValue {
    switch (result) {
        .temp_float => |i| {
            return FloatValue{ .temp_float_index = i };
        },
        .self_param => |i| {
            const module = self.first_pass_result.modules[self.module_index];
            const param = self.first_pass_result.module_params[module.first_param + i];
            if (param.param_type == .constant) {
                return FloatValue{ .self_param = i };
            }
            return null;
        },
        .literal => |literal| {
            return switch (literal) {
                .number => |n| FloatValue{ .literal = n },
                else => null,
            };
        },
        else => return null,
    }
}

fn getBufferValue(self: *CodegenState, result: ExpressionResult) ?BufferValue {
    switch (result) {
        .temp_buffer => |i| {
            return BufferValue{ .temp_buffer_index = i };
        },
        .self_param => |i| {
            const module = self.first_pass_result.modules[self.module_index];
            const param = self.first_pass_result.module_params[module.first_param + i];
            if (param.param_type == .buffer) {
                return BufferValue{ .self_param = i };
            }
            return null;
        },
        else => return null,
    }
}

// TODO eventually, genExpression should gain an optional parameter 'result_location' which is the lvalue of an assignment,
// if applicable. for example when setting the module's output, we don't want it to generate a temp which then has to be
// copied into the output. we want it to write straight to the output.
// but this is just an optimization and can be done later.

// generate bytecode instructions for an expression.
fn genExpression(self: *CodegenState, expression: *const Expression) GenError!ExpressionResult {
    switch (expression.inner) {
        .literal => |literal| {
            return ExpressionResult{ .literal = literal };
        },
        .self_param => |param_index| {
            return ExpressionResult{ .self_param = param_index };
        },
        .bin_arith => |m| {
            const ra = try genExpression(self, m.a);
            const rb = try genExpression(self, m.b);
            // float * float -> float
            if (getFloatValue(self, ra)) |a| {
                if (getFloatValue(self, rb)) |b| {
                    const temp_float_index = self.num_temp_floats;
                    self.num_temp_floats += 1;
                    try self.instructions.append(.{
                        .arith_float_float = .{
                            .operator = m.op,
                            .out_temp_float_index = temp_float_index,
                            .a = a,
                            .b = b,
                        },
                    });
                    return ExpressionResult{ .temp_float = temp_float_index };
                }
            }
            // buffer * float -> buffer
            if (getBufferValue(self, ra)) |a| {
                if (getFloatValue(self, rb)) |b| {
                    const temp_buffer_index = self.num_temps;
                    self.num_temps += 1;
                    try self.instructions.append(.{
                        .arith_buffer_float = .{
                            .operator = m.op,
                            .out_temp_buffer_index = temp_buffer_index,
                            .a = a,
                            .b = b,
                        },
                    });
                    return ExpressionResult{ .temp_buffer = temp_buffer_index };
                }
            }
            // float * buffer -> buffer (swap it to buffer * float)
            if (getFloatValue(self, ra)) |a| {
                if (getBufferValue(self, rb)) |b| {
                    const temp_buffer_index = self.num_temps;
                    self.num_temps += 1;
                    try self.instructions.append(.{
                        .arith_buffer_float = .{
                            .operator = m.op,
                            .out_temp_buffer_index = temp_buffer_index,
                            .a = b,
                            .b = a,
                        },
                    });
                    return ExpressionResult{ .temp_buffer = temp_buffer_index };
                }
            }
            // buffer * buffer -> buffer
            if (getBufferValue(self, ra)) |a| {
                if (getBufferValue(self, rb)) |b| {
                    const temp_buffer_index = self.num_temps;
                    self.num_temps += 1;
                    try self.instructions.append(.{
                        .arith_buffer_buffer = .{
                            .operator = m.op,
                            .out_temp_buffer_index = temp_buffer_index,
                            .a = a,
                            .b = b,
                        },
                    });
                    return ExpressionResult{ .temp_buffer = temp_buffer_index };
                }
            }
            std.debug.warn("ra: {}\nrb: {}\n", .{ ra, rb });
            return fail(self.source, expression.source_range, "invalid operand types", .{});
        },
        .call => |call| {
            const module = self.first_pass_result.modules[self.module_index];
            const params = self.first_pass_result.module_params[module.first_param .. module.first_param + module.num_params];
            const field = self.first_pass_result.module_fields[module.first_field + call.field_index];

            // the callee is guaranteed to have had its codegen done already (see second_pass), so its num_temps is known
            const callee_num_temps = self.codegen_results[field.resolved_module_index].num_temps;

            const callee_module = self.first_pass_result.modules[field.resolved_module_index];
            const callee_params = self.first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];

            var icall: InstrCall = .{
                .out_temp_buffer_index = self.num_temps,
                .field_index = call.field_index,
                .temps = std.ArrayList(usize).init(self.allocator),
                .args = try self.allocator.alloc(ExpressionResult, callee_params.len),
            };
            // TODO deinit
            self.num_temps += 1;

            // the callee needs temps for its own internal use
            var i: usize = 0;
            while (i < callee_num_temps) : (i += 1) {
                try icall.temps.append(self.num_temps);
                self.num_temps += 1;
            }

            // pass params
            for (callee_params) |param, j| {
                // find this arg in the call node. (not necessarily in the same order.)
                // FIXME - second_pass can return the param_index, not the name.
                const arg = for (call.args.span()) |a| {
                    if (std.mem.eql(u8, a.arg_name, param.name)) {
                        break a;
                    }
                } else unreachable; // we already checked for missing params in second_pass

                var arg_result = try genExpression(self, arg.value);

                // typecheck the argument
                switch (param.param_type) {
                    .boolean => {
                        const ok = switch (arg_result) {
                            .temp_buffer => false,
                            .temp_float => false,
                            .temp_bool => true,
                            .literal => |literal| literal == .boolean,
                            .self_param => |param_index| params[param_index].param_type == .boolean,
                        };
                        if (!ok) {
                            return fail(self.source, arg.value.source_range, "expected boolean value", .{});
                        }
                    },
                    .buffer => {
                        const Ok = enum { valid, invalid, convert };
                        const ok: Ok = switch (arg_result) {
                            .temp_buffer => .valid,
                            .temp_float => .convert,
                            .temp_bool => .invalid,
                            .literal => |literal| switch (literal) {
                                .number => Ok.convert,
                                else => Ok.invalid,
                            },
                            .self_param => |param_index| switch (params[param_index].param_type) {
                                .buffer => Ok.valid,
                                .constant => Ok.convert,
                                else => Ok.invalid,
                            },
                        };
                        if (ok == .convert) {
                            const temp_buffer_index = self.num_temps;
                            self.num_temps += 1;
                            try self.instructions.append(.{
                                .float_to_buffer = .{
                                    .out_temp_buffer_index = temp_buffer_index,
                                    .in = switch (arg_result) {
                                        .temp_float => |index| FloatValue{ .temp_float_index = index },
                                        .literal => |literal| switch (literal) {
                                            .number => |n| FloatValue{ .literal = n },
                                            else => unreachable,
                                        },
                                        .self_param => |param_index| FloatValue{ .self_param = param_index },
                                        else => unreachable,
                                    },
                                },
                            });
                            arg_result = .{ .temp_buffer = temp_buffer_index };
                        }
                        if (ok == .invalid) {
                            return fail(self.source, arg.value.source_range, "expected waveform value", .{});
                        }
                    },
                    .constant => {
                        const ok = switch (arg_result) {
                            .temp_buffer => false,
                            .temp_float => true,
                            .temp_bool => false,
                            .literal => |literal| literal == .number,
                            .self_param => |param_index| params[param_index].param_type == .constant,
                        };
                        if (!ok) {
                            return fail(self.source, arg.value.source_range, "expected constant value", .{});
                        }
                    },
                    .constant_or_buffer => {
                        const ok = switch (arg_result) {
                            .temp_buffer => true,
                            .temp_float => true,
                            .temp_bool => false,
                            .literal => |literal| literal == .number,
                            .self_param => |param_index| switch (params[param_index].param_type) {
                                .constant => true,
                                .buffer => true,
                                .constant_or_buffer => unreachable, // custom modules cannot use this type in their params (for now)
                                else => false,
                            },
                        };
                        if (!ok) {
                            return fail(self.source, arg.value.source_range, "expected constant or waveform value", .{});
                        }
                    },
                }

                icall.args[j] = arg_result;
            }

            try self.instructions.append(.{ .call = icall });

            return ExpressionResult{ .temp_buffer = icall.out_temp_buffer_index };
        },
    }
}

pub fn genOutputInstruction(self: *CodegenState, source_range: SourceRange, result: ExpressionResult) !void {
    switch (result) {
        .temp_buffer => |i| {
            try self.instructions.append(.{ .output = .{ .value = .{ .temp_buffer_index = i } } });
        },
        .temp_float => |i| {
            const temp_buffer_index = self.num_temps;
            self.num_temps += 1;
            try self.instructions.append(.{
                .float_to_buffer = .{
                    .out_temp_buffer_index = temp_buffer_index,
                    .in = .{ .temp_float_index = i },
                },
            });
            try self.instructions.append(.{ .output = .{ .value = .{ .temp_buffer_index = temp_buffer_index } } });
        },
        .temp_bool => return fail(self.source, source_range, "paint block cannot return a boolean", .{}),
        .literal => |literal| switch (literal) {
            .boolean => return fail(self.source, source_range, "paint block cannot return a boolean", .{}),
            .number => |n| {
                const temp_buffer_index = self.num_temps;
                self.num_temps += 1;
                try self.instructions.append(.{
                    .float_to_buffer = .{
                        .out_temp_buffer_index = temp_buffer_index,
                        .in = .{ .literal = n },
                    },
                });
                try self.instructions.append(.{ .output = .{ .value = .{ .temp_buffer_index = temp_buffer_index } } });
            },
        },
        .self_param => |i| {
            const module = self.first_pass_result.modules[self.module_index];
            const param = self.first_pass_result.module_params[module.first_param + i];
            switch (param.param_type) {
                .boolean => return fail(self.source, source_range, "paint block cannot return a boolean", .{}),
                .buffer => {
                    try self.instructions.append(.{ .output = .{ .value = .{ .self_param = i } } });
                },
                .constant => {
                    const temp_buffer_index = self.num_temps;
                    self.num_temps += 1;
                    try self.instructions.append(.{
                        .float_to_buffer = .{
                            .out_temp_buffer_index = temp_buffer_index,
                            .in = .{ .self_param = i },
                        },
                    });
                    try self.instructions.append(.{ .output = .{ .value = .{ .temp_buffer_index = temp_buffer_index } } });
                },
                .constant_or_buffer => unreachable, // impossible
            }
        },
    }
}

pub const CodeGenResult = struct {
    num_outputs: usize,
    num_temps: usize,
    instructions: []const Instruction, // owned slice (might need to remove `const` to make it free-able?)
};

// codegen_results is just there so we can read the num_temps of modules being called.
pub fn codegen(source: Source, codegen_results: []const CodeGenResult, first_pass_result: FirstPassResult, module_index: usize, expression: *const Expression, allocator: *std.mem.Allocator) !CodeGenResult {
    var self: CodegenState = .{
        .allocator = allocator,
        .source = source,
        .first_pass_result = first_pass_result,
        .codegen_results = codegen_results,
        .module_index = module_index,
        .instructions = std.ArrayList(Instruction).init(allocator),
        .num_temps = 0,
        .num_temp_floats = 0,
        .num_temp_bools = 0,
    };
    errdefer self.instructions.deinit();

    // generate code for the main expression
    const result = try genExpression(&self, expression);

    // generate code for copying the expression result to the output.
    // (later i'll implement some kind of result-location thing so genExpression can write directly to the output)
    try genOutputInstruction(&self, expression.source_range, result);

    // diagnostic print
    printBytecode(&self);

    return CodeGenResult{
        .num_outputs = 1,
        .num_temps = self.num_temps,
        .instructions = self.instructions.toOwnedSlice(),
    };
}
