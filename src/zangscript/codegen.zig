const std = @import("std");
const Source = @import("common.zig").Source;
const SourceRange = @import("common.zig").SourceRange;
const fail = @import("common.zig").fail;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const ModuleParam = @import("first_pass.zig").ModuleParam;
const ParamType = @import("first_pass.zig").ParamType;
const BinArithOp = @import("second_pass.zig").BinArithOp;
const Literal = @import("second_pass.zig").Literal;
const Local = @import("second_pass.zig").Local;
const Expression = @import("second_pass.zig").Expression;
const Statement = @import("second_pass.zig").Statement;
const Scope = @import("second_pass.zig").Scope;
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
// if it's a temp, the caller needs to make sure to release it (by calling
// releaseExpressionResult).
pub const ExpressionResult = union(enum) {
    temp_buffer_weak: usize, // not freed by releaseExpressionResult
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
    temps: []const usize,
    // list of argument param values (in the order of the callee module's params)
    args: []const ExpressionResult,
};

// i might consider replacing this begin/end pair with a single InstrDelay
// which actually contains a sublist of Instructions?
pub const InstrDelayBegin = struct {
    delay_index: usize,
    out_temp_buffer_index: usize,
    feedback_temp_buffer_index: usize,
};

pub const InstrDelayEnd = struct {
    delay_index: usize,
    out_temp_buffer_index: usize,
    inner_value: BufferValue,
};

pub const InstrCopyBuffer = struct {
    out_temp_buffer_index: usize,
    in: BufferValue,
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
    copy_buffer: InstrCopyBuffer,
    float_to_buffer: InstrFloatToBuffer,
    arith_float_float: InstrArithFloatFloat,
    arith_buffer_float: InstrArithBufferFloat,
    arith_buffer_buffer: InstrArithBufferBuffer,
    call: InstrCall,
    delay_begin: InstrDelayBegin,
    delay_end: InstrDelayEnd,
    output: InstrOutput,
};

pub const DelayDecl = struct {
    num_samples: usize,
};

pub const CodegenState = struct {
    allocator: *std.mem.Allocator,
    source: Source,
    first_pass_result: FirstPassResult,
    codegen_results: []const CodeGenResult,
    module_index: usize,
    locals: []const Local,
    instructions: std.ArrayList(Instruction),
    temp_buffers: TempManager,
    temp_floats: TempManager,
    temp_bools: TempManager,
    local_temps: []?usize,
    delays: std.ArrayList(DelayDecl),
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
        .temp_buffer_weak,
        .temp_buffer,
        .temp_bool,
        => return null,
    }
}

fn getBufferValue(self: *CodegenState, result: ExpressionResult) ?BufferValue {
    switch (result) {
        .temp_buffer_weak => |i| {
            return BufferValue{ .temp_buffer_index = i };
        },
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
        .temp_float,
        .temp_bool,
        .literal,
        => return null,
    }
}

const TempManager = struct {
    slot_claimed: std.ArrayList(bool),

    fn init(allocator: *std.mem.Allocator) TempManager {
        return .{
            .slot_claimed = std.ArrayList(bool).init(allocator),
        };
    }

    fn deinit(self: *TempManager) void {
        // check for leaks
        for (self.slot_claimed.span()) |in_use| {
            std.debug.assert(!in_use);
        }
        self.slot_claimed.deinit();
    }

    fn claim(self: *TempManager) !usize {
        for (self.slot_claimed.span()) |*in_use, index| {
            if (!in_use.*) {
                in_use.* = true;
                return index;
            }
        }
        const index = self.slot_claimed.len;
        try self.slot_claimed.append(true);
        return index;
    }

    fn release(self: *TempManager, index: usize) void {
        std.debug.assert(self.slot_claimed.span()[index]);
        self.slot_claimed.span()[index] = false;
    }

    fn finalCount(self: *const TempManager) usize {
        return self.slot_claimed.len;
    }
};

// TODO eventually, genExpression should gain an optional parameter 'result_location' which is the lvalue of an assignment,
// if applicable. for example when setting the module's output, we don't want it to generate a temp which then has to be
// copied into the output. we want it to write straight to the output.
// but this is just an optimization and can be done later.

fn releaseExpressionResult(self: *CodegenState, result: ExpressionResult) void {
    switch (result) {
        .temp_buffer_weak => {},
        .temp_buffer => |i| self.temp_buffers.release(i),
        .temp_float => |i| self.temp_floats.release(i),
        .temp_bool => |i| self.temp_bools.release(i),
        .literal => {},
        .self_param => {},
    }
}

// generate bytecode instructions for an expression.
fn genExpression(self: *CodegenState, expression: *const Expression, maybe_feedback_temp_index: ?usize) GenError!ExpressionResult {
    switch (expression.inner) {
        .literal => |literal| {
            return ExpressionResult{ .literal = literal };
        },
        .local => |index| {
            return ExpressionResult{ .temp_buffer_weak = self.local_temps[index].? };
        },
        .self_param => |param_index| {
            return ExpressionResult{ .self_param = param_index };
        },
        .bin_arith => |m| {
            const ra = try genExpression(self, m.a, maybe_feedback_temp_index);
            defer releaseExpressionResult(self, ra);
            const rb = try genExpression(self, m.b, maybe_feedback_temp_index);
            defer releaseExpressionResult(self, rb);
            // float * float -> float
            if (getFloatValue(self, ra)) |a| {
                if (getFloatValue(self, rb)) |b| {
                    const temp_float_index = try self.temp_floats.claim();
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
                    const temp_buffer_index = try self.temp_buffers.claim();
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
                    const temp_buffer_index = try self.temp_buffers.claim();
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
                    const temp_buffer_index = try self.temp_buffers.claim();
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

            // the callee needs temps for its own internal use
            var temps = try self.allocator.alloc(usize, callee_num_temps); // TODO free this somewhere
            for (temps) |*ptr| {
                ptr.* = try self.temp_buffers.claim();
            }
            defer {
                for (temps) |temp_buffer_index| {
                    self.temp_buffers.release(temp_buffer_index);
                }
            }

            // pass params
            var args = try self.allocator.alloc(ExpressionResult, callee_params.len); // TODO free this somewhere
            var args_filled: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < args_filled) : (i += 1) {
                    releaseExpressionResult(self, args[i]);
                }
            }
            for (callee_params) |param, i| {
                // find this arg in the call node. (they are not necessarily in the same order)
                const arg = for (call.args.span()) |a| {
                    if (a.callee_param_index == i) {
                        break a;
                    }
                } else unreachable; // we already checked for missing params in second_pass

                var arg_result = try genExpression(self, arg.value, maybe_feedback_temp_index);

                // typecheck the argument
                switch (param.param_type) {
                    .boolean => {
                        const ok = switch (arg_result) {
                            .temp_buffer_weak => false,
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
                            .temp_buffer_weak => .valid,
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
                            const temp_buffer_index = try self.temp_buffers.claim();
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
                            releaseExpressionResult(self, arg_result);
                            arg_result = .{ .temp_buffer = temp_buffer_index };
                        }
                        if (ok == .invalid) {
                            return fail(self.source, arg.value.source_range, "expected waveform value", .{});
                        }
                    },
                    .constant => {
                        const ok = switch (arg_result) {
                            .temp_buffer_weak => false,
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
                            .temp_buffer_weak => true,
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
                    .one_of => |e| {
                        const ok = switch (arg_result) {
                            // enum values can only exist as literals
                            .literal => |literal| switch (literal) {
                                .enum_value => |str| for (e.values) |allowed_value| {
                                    if (std.mem.eql(u8, allowed_value, str)) {
                                        break true;
                                    }
                                } else {
                                    // TODO list the allowed enum values
                                    return fail(self.source, arg.value.source_range, "not one of the allowed enum values", .{});
                                },
                                else => false,
                            },
                            else => false,
                        };
                        if (!ok) {
                            // TODO list the allowed enum values
                            return fail(self.source, arg.value.source_range, "expected enum value", .{});
                        }
                    },
                }

                args[i] = arg_result;
                args_filled += 1;
            }

            const out_temp_buffer_index = try self.temp_buffers.claim();

            try self.instructions.append(.{
                .call = .{
                    .out_temp_buffer_index = out_temp_buffer_index,
                    .field_index = call.field_index,
                    .temps = temps,
                    .args = args,
                },
            });

            for (callee_params) |param, i| {
                releaseExpressionResult(self, args[i]);
            }

            return ExpressionResult{ .temp_buffer = out_temp_buffer_index };
        },
        .delay => |delay| {
            if (maybe_feedback_temp_index != null) {
                // i might be able to support this, but why?
                return fail(self.source, expression.source_range, "you cannot nest delay operations", .{});
            }

            const delay_index = self.delays.len;
            try self.delays.append(.{ .num_samples = delay.num_samples });

            const feedback_temp_index = try self.temp_buffers.claim();
            defer self.temp_buffers.release(feedback_temp_index);

            const temp_buffer_index = try self.temp_buffers.claim();
            try self.instructions.append(.{
                .delay_begin = .{
                    .delay_index = delay_index,
                    .out_temp_buffer_index = temp_buffer_index,
                    .feedback_temp_buffer_index = feedback_temp_index, // do i need this?
                },
            });

            // FIXME - i'm stuck here. i can't get the output out of the delay block.
            // i think i need to implement result locations in second_pass before i can get this working.
            //for (delay.scope.statements.span()) |statement| {
            //    try genStatement(self, statement, feedback_temp_index);
            //}

            // BEGIN HACK
            // i'm just grabbing the last output statement and using its expression.
            // if it referenced any locals that were declared within the delay block, i guess this won't work.
            // see FIXME comment above
            var maybe_last_expr: ?*const Expression = null;
            for (delay.scope.statements.span()) |statement| {
                switch (statement) {
                    .output => |expr| maybe_last_expr = expr,
                    else => {},
                }
            }
            const expr = maybe_last_expr.?;
            const inner_result = try genExpression(self, expr, feedback_temp_index);
            defer releaseExpressionResult(self, inner_result);
            // END HACK

            const inner_value = getBufferValue(self, inner_result) orelse {
                return fail(self.source, expression.source_range, "invalid operand types", .{});
            };

            try self.instructions.append(.{
                .delay_end = .{
                    .delay_index = delay_index,
                    .out_temp_buffer_index = temp_buffer_index,
                    .inner_value = inner_value,
                },
            });

            return ExpressionResult{ .temp_buffer = temp_buffer_index };
        },
        .feedback => {
            const feedback_temp_index = maybe_feedback_temp_index orelse {
                return fail(self.source, expression.source_range, "`feedback` can only be used within a `delay` operation", .{});
            };
            return ExpressionResult{ .temp_buffer_weak = feedback_temp_index };
        },
    }
}

fn genOutput(self: *CodegenState, expression: *const Expression, maybe_feedback_temp_index: ?usize) GenError!void {
    const result = try genExpression(self, expression, maybe_feedback_temp_index);
    defer releaseExpressionResult(self, result);

    const source_range = expression.source_range;

    switch (result) {
        .temp_buffer_weak => |i| {
            try self.instructions.append(.{ .output = .{ .value = .{ .temp_buffer_index = i } } });
        },
        .temp_buffer => |i| {
            try self.instructions.append(.{ .output = .{ .value = .{ .temp_buffer_index = i } } });
        },
        .temp_float => |i| {
            const temp_buffer_index = try self.temp_buffers.claim();
            defer self.temp_buffers.release(temp_buffer_index);
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
                const temp_buffer_index = try self.temp_buffers.claim();
                defer self.temp_buffers.release(temp_buffer_index);
                try self.instructions.append(.{
                    .float_to_buffer = .{
                        .out_temp_buffer_index = temp_buffer_index,
                        .in = .{ .literal = n },
                    },
                });
                try self.instructions.append(.{ .output = .{ .value = .{ .temp_buffer_index = temp_buffer_index } } });
            },
            .enum_value => return fail(self.source, source_range, "paint block cannot return an enum value", .{}),
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
                    const temp_buffer_index = try self.temp_buffers.claim();
                    defer self.temp_buffers.release(temp_buffer_index);
                    try self.instructions.append(.{
                        .float_to_buffer = .{
                            .out_temp_buffer_index = temp_buffer_index,
                            .in = .{ .self_param = i },
                        },
                    });
                    try self.instructions.append(.{ .output = .{ .value = .{ .temp_buffer_index = temp_buffer_index } } });
                },
                .constant_or_buffer => unreachable, // impossible
                .one_of => unreachable, // impossible
            }
        },
    }
}

fn genStatement(self: *CodegenState, statement: Statement, maybe_feedback_temp_index: ?usize) GenError!void {
    switch (statement) {
        .let_assignment => |x| {
            // for now, only buffer type is supported for let-assignments
            const result = try genExpression(self, x.expression, maybe_feedback_temp_index);

            // TODO support other types? in other cases, no temp should be generated, probably?
            // like self_param and literal can just be passed through since there's no work
            // involved in getting their value
            const temp_buffer_index = switch (result) {
                //.temp_buffer_weak => |i| {},
                .temp_buffer => |i| {
                    // if genExpression allocated a new temp for its result, record that temp
                    // to be released at the end of codegen (otherwise a leak will be detected)
                    // note: be careful if support for temp_buffer_weak is added. we'll want to record
                    // the statement_temp, but NOT release it at the end, since something else is already
                    // committed to releasing it
                    self.local_temps[x.local_index] = i;
                },
                //temp_float: usize,
                //temp_bool: usize,
                //literal: Literal,
                //self_param: usize,
                else => {
                    return fail(self.source, x.expression.source_range, "assignment value must be a buffer-typed expression", .{});
                },
            };

            // old implementation (copying):

            //const temp_buffer_index = try self.temp_buffers.claim();
            //self.statement_temps[statement_index] = temp_buffer_index;

            //// TODO genExpression should be able to take an optional result-location.
            //// only if not provided will it generate a temp for its result
            //const result = try genExpression(self, x.expression, maybe_feedback_temp_index);
            //defer releaseExpressionResult(self, result);

            //try self.instructions.append(.{
            //    .copy_buffer = .{
            //        .out_temp_buffer_index = temp_buffer_index,
            //        .in = .{
            //            .temp_buffer_index = switch (result) {
            //                .temp_buffer_weak => |i| i,
            //                .temp_buffer => |i| i,
            //                else => unreachable, // FIXME - if reachable this should be a proper error
            //            },
            //        },
            //    },
            //});
        },
        .output => |expression| {
            try genOutput(self, expression, maybe_feedback_temp_index);
        },
    }
}

pub const CodeGenResult = struct {
    num_outputs: usize,
    num_temps: usize,
    delays: []const DelayDecl, // owned slice
    instructions: []const Instruction, // owned slice (might need to remove `const` to make it free-able?)
};

// codegen_results is just there so we can read the num_temps of modules being called.
pub fn codegen(
    source: Source,
    codegen_results: []const CodeGenResult,
    first_pass_result: FirstPassResult,
    module_index: usize,
    locals: []const Local,
    scope: *const Scope,
    allocator: *std.mem.Allocator,
) !CodeGenResult {
    var self: CodegenState = .{
        .allocator = allocator,
        .source = source,
        .first_pass_result = first_pass_result,
        .codegen_results = codegen_results,
        .module_index = module_index,
        .locals = locals,
        .instructions = std.ArrayList(Instruction).init(allocator),
        .temp_buffers = TempManager.init(allocator),
        .temp_floats = TempManager.init(allocator),
        .temp_bools = TempManager.init(allocator),
        .local_temps = try allocator.alloc(?usize, locals.len),
        .delays = std.ArrayList(DelayDecl).init(allocator),
    };
    errdefer self.instructions.deinit();
    errdefer self.delays.deinit();
    defer self.temp_buffers.deinit();
    defer self.temp_floats.deinit();
    defer self.temp_bools.deinit();
    defer allocator.free(self.local_temps);

    std.mem.set(?usize, self.local_temps, null);

    for (scope.statements.span()) |statement| {
        try genStatement(&self, statement, null);
    }

    for (self.local_temps) |maybe_temp_buffer_index| {
        const temp_buffer_index = maybe_temp_buffer_index orelse continue;
        self.temp_buffers.release(temp_buffer_index);
    }

    // diagnostic print
    printBytecode(&self);

    return CodeGenResult{
        .num_outputs = 1,
        .num_temps = self.temp_buffers.finalCount(),
        .delays = self.delays.toOwnedSlice(),
        .instructions = self.instructions.toOwnedSlice(),
    };
}
