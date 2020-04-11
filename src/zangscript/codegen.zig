const std = @import("std");
const Source = @import("common.zig").Source;
const SourceRange = @import("common.zig").SourceRange;
const fail = @import("common.zig").fail;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const ModuleParam = @import("first_pass.zig").ModuleParam;
const ParamType = @import("first_pass.zig").ParamType;
const CallArg = @import("second_pass.zig").CallArg;
const BinArithOp = @import("second_pass.zig").BinArithOp;
const Field = @import("second_pass.zig").Field;
const Local = @import("second_pass.zig").Local;
const Expression = @import("second_pass.zig").Expression;
const Statement = @import("second_pass.zig").Statement;
const LetAssignment = @import("second_pass.zig").LetAssignment;
const Scope = @import("second_pass.zig").Scope;
const builtins = @import("builtins.zig").builtins;
const printBytecode = @import("codegen_print.zig").printBytecode;

// expression will return how it stored its result.
// if it's a temp, the caller needs to make sure to release it (by calling
// releaseExpressionResult).
pub const ExpressionResult = union(enum) {
    nothing,
    temp_buffer_weak: usize, // not freed by releaseExpressionResult
    temp_buffer: usize,
    temp_float: usize,
    temp_bool: usize,
    literal_boolean: bool,
    literal_number: f32,
    literal_enum_value: []const u8,
    self_param: usize,
};

pub const FloatValue = union(enum) {
    temp_float_index: usize,
    self_param: usize, // guaranteed to be of type `constant`
    literal: f32,
};

pub const BufferDest = union(enum) {
    temp_buffer_index: usize,
    output_index: usize,
};

pub const BufferValue = union(enum) {
    temp_buffer_index: usize,
    self_param: usize, // guaranteed to be of type `buffer`
};

// call one of self's fields (paint the child module)
pub const InstrCall = struct {
    // paint always results in a buffer.
    out: BufferDest,
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
    out: BufferDest,
    feedback_out_temp_buffer_index: usize,
    feedback_temp_buffer_index: usize,
};

pub const InstrDelayEnd = struct {
    delay_index: usize,
    out: BufferDest,
    feedback_out_temp_buffer_index: usize,
};

pub const InstrCopyBuffer = struct {
    out: BufferDest,
    in: BufferValue,
};

pub const InstrFloatToBuffer = struct {
    out: BufferDest,
    in: FloatValue,
};

pub const InstrCobToBuffer = struct {
    out: BufferDest,
    in_self_param: usize,
};

pub const InstrNegateFloatToFloat = struct {
    out_temp_float_index: usize,
    a: FloatValue,
};

pub const InstrNegateBufferToBuffer = struct {
    out: BufferDest,
    a: BufferValue,
};

pub const InstrArithFloatFloat = struct {
    out_temp_float_index: usize,
    operator: BinArithOp,
    a: FloatValue,
    b: FloatValue,
};

pub const InstrArithFloatBuffer = struct {
    out: BufferDest,
    operator: BinArithOp,
    a: FloatValue,
    b: BufferValue,
};

pub const InstrArithBufferFloat = struct {
    out: BufferDest,
    operator: BinArithOp,
    a: BufferValue,
    b: FloatValue,
};

pub const InstrArithBufferBuffer = struct {
    out: BufferDest,
    operator: BinArithOp,
    a: BufferValue,
    b: BufferValue,
};

pub const Instruction = union(enum) {
    copy_buffer: InstrCopyBuffer,
    float_to_buffer: InstrFloatToBuffer,
    cob_to_buffer: InstrCobToBuffer,
    negate_float_to_float: InstrNegateFloatToFloat,
    negate_buffer_to_buffer: InstrNegateBufferToBuffer,
    arith_float_float: InstrArithFloatFloat,
    arith_float_buffer: InstrArithFloatBuffer,
    arith_buffer_float: InstrArithBufferFloat,
    arith_buffer_buffer: InstrArithBufferBuffer,
    call: InstrCall,
    delay_begin: InstrDelayBegin,
    delay_end: InstrDelayEnd,
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
    fields: []const Field,
    locals: []const Local,
    instructions: std.ArrayList(Instruction),
    temp_buffers: TempManager,
    // temp floats and bools are just consts in zig code so they can't be reused
    num_temp_floats: usize,
    num_temp_bools: usize,
    local_temps: []?usize,
    delays: std.ArrayList(DelayDecl),
};

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

pub const GenError = error{
    Failed,
    OutOfMemory,
};

fn getFloatValue(self: *CodegenState, result: ExpressionResult) ?FloatValue {
    switch (result) {
        .nothing => unreachable,
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
        .literal_number => |value| {
            return FloatValue{ .literal = value };
        },
        .literal_boolean,
        .literal_enum_value,
        .temp_buffer_weak,
        .temp_buffer,
        .temp_bool,
        => return null,
    }
}

fn getBufferValue(self: *CodegenState, result: ExpressionResult) ?BufferValue {
    switch (result) {
        .nothing => unreachable,
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
        .literal_boolean,
        .literal_number,
        .literal_enum_value,
        => return null,
    }
}

fn releaseExpressionResult(self: *CodegenState, result: ExpressionResult) void {
    switch (result) {
        .temp_buffer => |i| self.temp_buffers.release(i),
        .nothing,
        .temp_buffer_weak,
        .temp_float,
        .temp_bool,
        .literal_boolean,
        .literal_number,
        .literal_enum_value,
        .self_param,
        => {},
    }
}

// return something that can be used as a call arg.
// generate a temp if necessary, but literals and self_params can be returned as is (avoid redundant copy)
fn coerceParam(self: *CodegenState, sr: SourceRange, param_type: ParamType, result: ExpressionResult) GenError!ExpressionResult {
    const module = self.first_pass_result.modules[self.module_index];
    const params = self.first_pass_result.module_params[module.first_param .. module.first_param + module.num_params];

    switch (param_type) {
        .boolean => {
            const ok = switch (result) {
                .nothing => unreachable,
                .temp_buffer_weak => false,
                .temp_buffer => false,
                .temp_float => false,
                .temp_bool => true,
                .literal_boolean => true,
                .literal_number => false,
                .literal_enum_value => false,
                .self_param => |param_index| params[param_index].param_type == .boolean,
            };
            if (!ok) {
                return fail(self.source, sr, "expected boolean value", .{});
            }
            return result;
        },
        .buffer => {
            const Ok = union(enum) { valid, invalid, convert: FloatValue };
            const ok: Ok = switch (result) {
                .nothing => unreachable,
                .temp_buffer_weak => .valid,
                .temp_buffer => .valid,
                .temp_float => |index| .{ .convert = FloatValue{ .temp_float_index = index } },
                .temp_bool => .invalid,
                .literal_boolean => .invalid,
                .literal_number => |value| Ok{ .convert = FloatValue{ .literal = value } },
                .literal_enum_value => .invalid,
                .self_param => |param_index| switch (params[param_index].param_type) {
                    .buffer => Ok{ .valid = {} },
                    .constant => Ok{ .convert = FloatValue{ .self_param = param_index } },
                    else => Ok{ .invalid = {} },
                },
            };
            switch (ok) {
                .valid => return result,
                .invalid => return fail(self.source, sr, "expected waveform value", .{}),
                .convert => |value| {
                    const temp_buffer_index = try self.temp_buffers.claim();
                    try self.instructions.append(.{
                        .float_to_buffer = .{
                            .out = .{ .temp_buffer_index = temp_buffer_index },
                            .in = value,
                        },
                    });
                    releaseExpressionResult(self, result);
                    return ExpressionResult{ .temp_buffer = temp_buffer_index };
                },
            }
        },
        .constant => {
            const ok = switch (result) {
                .nothing => unreachable,
                .temp_buffer_weak => false,
                .temp_buffer => false,
                .temp_float => true,
                .temp_bool => false,
                .literal_boolean => false,
                .literal_number => true,
                .literal_enum_value => false,
                .self_param => |param_index| params[param_index].param_type == .constant,
            };
            if (!ok) {
                return fail(self.source, sr, "expected constant value", .{});
            }
            return result;
        },
        .constant_or_buffer => {
            // accept both constants and buffers. codegen_zig will take care of wrapping
            // them in the correct way
            const ok = switch (result) {
                .nothing => unreachable,
                .temp_buffer_weak => true,
                .temp_buffer => true,
                .temp_float => true,
                .temp_bool => false,
                .literal_boolean => false,
                .literal_number => true,
                .literal_enum_value => false,
                .self_param => |param_index| switch (params[param_index].param_type) {
                    .boolean => false,
                    .constant => true,
                    .buffer => true,
                    .constant_or_buffer => unreachable, // these became buffers as soon as they came out of a self_param
                    .one_of => unreachable, // ditto
                },
            };
            if (!ok) {
                return fail(self.source, sr, "expected constant or waveform value", .{});
            }
            return result;
        },
        .one_of => |e| {
            const ok = switch (result) {
                // enum values can only exist as literals
                .literal_enum_value => |str|
                    for (e.values) |allowed_value| {
                        if (std.mem.eql(u8, allowed_value, str)) {
                            break true;
                        }
                    } else {
                        // TODO list the allowed enum values
                        return fail(self.source, sr, "not one of the allowed enum values", .{});
                    },
                else => false,
            };
            if (!ok) {
                // TODO list the allowed enum values
                return fail(self.source, sr, "expected enum value", .{});
            }
            return result;
        },
    }
}

// like the above, but destination is always of buffer type, and we always write to it.
// (so if the value is a self_param, we copy it)
fn coerceAssignment(self: *CodegenState, sr: SourceRange, result_loc: BufferDest, result: ExpressionResult) GenError!void {
    defer releaseExpressionResult(self, result);

    switch (result) {
        .nothing => unreachable,
        .temp_buffer_weak => |temp_buffer_index| {
            try self.instructions.append(.{
                .copy_buffer = .{
                    .out = result_loc,
                    .in = .{ .temp_buffer_index = temp_buffer_index },
                },
            });
        },
        .temp_buffer => |temp_buffer_index| {
            try self.instructions.append(.{
                .copy_buffer = .{
                    .out = result_loc,
                    .in = .{ .temp_buffer_index = temp_buffer_index },
                },
            });
        },
        .temp_float => |temp_float_index| {
            try self.instructions.append(.{
                .float_to_buffer = .{
                    .out = result_loc,
                    .in = .{ .temp_float_index = temp_float_index },
                },
            });
        },
        .temp_bool => {
            return fail(self.source, sr, "buffer-typed result loc cannot accept boolean", .{});
        },
        .literal_boolean => {
            return fail(self.source, sr, "buffer-typed result loc cannot accept boolean", .{});
        },
        .literal_number => |value| {
            try self.instructions.append(.{
                .float_to_buffer = .{
                    .out = result_loc,
                    .in = .{ .literal = value },
                },
            });
        },
        .literal_enum_value => {
            return fail(self.source, sr, "buffer-typed result loc cannot accept enum value", .{});
        },
        .self_param => |param_index| {
            const module = self.first_pass_result.modules[self.module_index];
            const params = self.first_pass_result.module_params[module.first_param .. module.first_param + module.num_params];
            const param_type = params[param_index].param_type;

            switch (param_type) {
                .boolean => {
                    return fail(self.source, sr, "buffer-typed result loc cannot accept boolean", .{});
                },
                .buffer => {
                    try self.instructions.append(.{
                        .copy_buffer = .{
                            .out = result_loc,
                            .in = .{ .self_param = param_index },
                        },
                    });
                },
                .constant => {
                    try self.instructions.append(.{
                        .float_to_buffer = .{
                            .out = result_loc,
                            .in = .{ .self_param = param_index },
                        },
                    });
                },
                .constant_or_buffer => unreachable, // these became buffers as soon as they came out of a self_param
                .one_of => unreachable, // only builtin params are allowed to use this
            }
        },
    }
}

const ResultInfo = union(enum) {
    none,
    param_type: ParamType,
    result_loc: BufferDest,
};

fn coerce(self: *CodegenState, sr: SourceRange, result_info: ResultInfo, result: ExpressionResult) GenError!ExpressionResult {
    switch (result_info) {
        .none => {
            return result;
        },
        .param_type => |param_type| {
            return try coerceParam(self, sr, param_type, result);
        },
        .result_loc => |result_loc| {
            try coerceAssignment(self, sr, result_loc, result);
            return ExpressionResult.nothing;
        },
    }
}

// generate bytecode instructions for an expression.
fn genExpression(self: *CodegenState, expression: *const Expression, result_info: ResultInfo, maybe_feedback_temp_index: ?usize) GenError!ExpressionResult {
    const sr = expression.source_range;

    switch (expression.inner) {
        .literal_boolean => |value| {
            return coerce(self, sr, result_info, .{ .literal_boolean = value });
        },
        .literal_number => |value| {
            return coerce(self, sr, result_info, .{ .literal_number = value });
        },
        .literal_enum_value => |value| {
            return coerce(self, sr, result_info, .{ .literal_enum_value = value });
        },
        .local => |local_index| {
            return coerce(self, sr, result_info, .{ .temp_buffer_weak = self.local_temps[local_index].? });
        },
        .self_param => |param_index| {
            const module = self.first_pass_result.modules[self.module_index];
            const param = self.first_pass_result.module_params[module.first_param + param_index];
            if (param.param_type == .constant_or_buffer) {
                // immediately turn constant_or_buffer into buffer (most of the rest of codegen
                // isn't able to work with constant_or_buffer)
                const temp_buffer_index = try self.temp_buffers.claim();
                try self.instructions.append(.{
                    .cob_to_buffer = .{
                        // TODO look at result_info and use that output
                        .out = .{ .temp_buffer_index = temp_buffer_index },
                        .in_self_param = param_index,
                    },
                });
                return coerce(self, sr, result_info, .{ .temp_buffer = temp_buffer_index });
            } else {
                return coerce(self, sr, result_info, .{ .self_param = param_index });
            }
        },
        .negate => |expr| {
            const ra = try genExpression(self, expr, .none, maybe_feedback_temp_index);
            defer releaseExpressionResult(self, ra);

            if (getFloatValue(self, ra)) |a| {
                const temp_float_index = self.num_temp_floats;
                self.num_temp_floats += 1;
                try self.instructions.append(.{
                    .negate_float_to_float = .{
                        .out_temp_float_index = temp_float_index,
                        .a = a,
                    },
                });
                return coerce(self, sr, result_info, .{ .temp_float = temp_float_index });
            }
            if (getBufferValue(self, ra)) |a| {
                const temp_buffer_index = try self.temp_buffers.claim();
                try self.instructions.append(.{
                    .negate_buffer_to_buffer = .{
                        .out = .{ .temp_buffer_index = temp_buffer_index },
                        .a = a,
                    },
                });
                return coerce(self, sr, result_info, .{ .temp_buffer = temp_buffer_index });
            }
            return fail(self.source, expression.source_range, "invalid operand type", .{});
        },
        .bin_arith => |m| {
            const ra = try genExpression(self, m.a, .none, maybe_feedback_temp_index);
            defer releaseExpressionResult(self, ra);
            const rb = try genExpression(self, m.b, .none, maybe_feedback_temp_index);
            defer releaseExpressionResult(self, rb);

            // float * float -> float
            if (getFloatValue(self, ra)) |a| {
                if (getFloatValue(self, rb)) |b| {
                    // no result_loc shenanigans here because result_locs can't have float type (only buffer type)
                    const temp_float_index = self.num_temp_floats;
                    self.num_temp_floats += 1;
                    try self.instructions.append(.{
                        .arith_float_float = .{
                            .out_temp_float_index = temp_float_index,
                            .operator = m.op,
                            .a = a,
                            .b = b,
                        },
                    });
                    return coerce(self, sr, result_info, .{ .temp_float = temp_float_index });
                }
            }
            // buffer * float -> buffer
            if (getBufferValue(self, ra)) |a| {
                if (getFloatValue(self, rb)) |b| {
                    var result2: ExpressionResult = .nothing;
                    const out: BufferDest = switch (result_info) {
                        .none => null,
                        .param_type => null,
                        .result_loc => |result_loc| result_loc,
                    } orelse blk: {
                        const temp_buffer_index = try self.temp_buffers.claim();
                        result2 = .{ .temp_buffer = temp_buffer_index };
                        break :blk .{ .temp_buffer_index = temp_buffer_index };
                    };
                    try self.instructions.append(.{
                        .arith_buffer_float = .{
                            .out = out,
                            .operator = m.op,
                            .a = a,
                            .b = b,
                        },
                    });
                    return result2;
                }
            }
            // float * buffer -> buffer
            if (getFloatValue(self, ra)) |a| {
                if (getBufferValue(self, rb)) |b| {
                    var result2: ExpressionResult = .nothing;
                    const out: BufferDest = switch (result_info) {
                        .none => null,
                        .param_type => null,
                        .result_loc => |result_loc| result_loc,
                    } orelse blk: {
                        const temp_buffer_index = try self.temp_buffers.claim();
                        result2 = .{ .temp_buffer = temp_buffer_index };
                        break :blk .{ .temp_buffer_index = temp_buffer_index };
                    };
                    try self.instructions.append(.{
                        .arith_float_buffer = .{
                            .out = out,
                            .operator = m.op,
                            .a = a,
                            .b = b,
                        },
                    });
                    return result2;
                }
            }
            // buffer * buffer -> buffer
            if (getBufferValue(self, ra)) |a| {
                if (getBufferValue(self, rb)) |b| {
                    var result2: ExpressionResult = .nothing;
                    const out: BufferDest = switch (result_info) {
                        .none => null,
                        .param_type => null,
                        .result_loc => |result_loc| result_loc,
                    } orelse blk: {
                        const temp_buffer_index = try self.temp_buffers.claim();
                        result2 = .{ .temp_buffer = temp_buffer_index };
                        break :blk .{ .temp_buffer_index = temp_buffer_index };
                    };
                    try self.instructions.append(.{
                        .arith_buffer_buffer = .{
                            .out = out,
                            .operator = m.op,
                            .a = a,
                            .b = b,
                        },
                    });
                    return result2;
                }
            }
            std.debug.warn("ra: {}\nrb: {}\n", .{ ra, rb });
            return fail(self.source, expression.source_range, "invalid operand types", .{});
        },
        .call => |call| {
            const module = self.first_pass_result.modules[self.module_index];
            const field = self.fields[call.field_index];

            // the callee is guaranteed to have had its codegen done already (see second_pass), so its num_temps is known
            const callee_num_temps = self.codegen_results[field.resolved_module_index].num_temps;

            const callee_module = self.first_pass_result.modules[field.resolved_module_index];
            const callee_params = self.first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];

            // pass params
            var args = try self.allocator.alloc(ExpressionResult, callee_params.len); // TODO free this somewhere
            var args_filled: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < args_filled) : (i += 1) {
                    releaseExpressionResult(self, args[i]);
                }
            }
            for (call.args) |a| {
                for (callee_params) |param| {
                    if (std.mem.eql(u8, a.param_name, param.name)) break;
                } else {
                    return fail(self.source, a.param_name_token.source_range, "invalid param `<`", .{});
                }
            }
            for (callee_params) |param, i| {
                // find this arg in the call node
                // FIXME when these errors happen there is a temps leak
                var maybe_arg: ?CallArg = null;
                for (call.args) |a| {
                    if (std.mem.eql(u8, a.param_name, param.name)) {
                        if (maybe_arg != null) {
                            return fail(self.source, a.param_name_token.source_range, "param `<` provided more than once", .{});
                        }
                        maybe_arg = a;
                    }
                }
                const arg = maybe_arg orelse {
                    return fail(self.source, sr, "call is missing param `#`", .{param.name});
                };
                args[i] = try genExpression(self, arg.value, .{ .param_type = param.param_type }, maybe_feedback_temp_index);
                args_filled += 1;
            }

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

            var result2: ExpressionResult = .nothing;
            const out: BufferDest = switch (result_info) {
                .none => null,
                .param_type => null,
                .result_loc => |result_loc| result_loc,
            } orelse blk: {
                const temp_buffer_index = try self.temp_buffers.claim();
                result2 = .{ .temp_buffer = temp_buffer_index };
                break :blk .{ .temp_buffer_index = temp_buffer_index };
            };
            try self.instructions.append(.{
                .call = .{
                    .out = out,
                    .field_index = call.field_index,
                    .temps = temps,
                    .args = args,
                },
            });
            for (callee_params) |param, i| {
                releaseExpressionResult(self, args[i]);
            }
            return result2;
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

            var result2: ExpressionResult = .nothing;
            const out: BufferDest = switch (result_info) {
                .none => null,
                .param_type => null,
                .result_loc => |result_loc| result_loc,
            } orelse blk: {
                const temp_buffer_index = try self.temp_buffers.claim();
                result2 = .{ .temp_buffer = temp_buffer_index };
                break :blk .{ .temp_buffer_index = temp_buffer_index };
            };

            const feedback_out_temp_index = try self.temp_buffers.claim();
            defer self.temp_buffers.release(feedback_out_temp_index);

            try self.instructions.append(.{
                .delay_begin = .{
                    .out = out,
                    .delay_index = delay_index,
                    .feedback_out_temp_buffer_index = feedback_out_temp_index,
                    .feedback_temp_buffer_index = feedback_temp_index, // do i need this?
                },
            });

            for (delay.scope.statements.span()) |statement| {
                switch (statement) {
                    .let_assignment => |x| {
                        try genLetAssignment(self, x, feedback_temp_index);
                    },
                    .output => |expr| {
                        const result = try genExpression(self, expr, .{ .result_loc = out }, feedback_temp_index);
                        defer releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
                    },
                    .feedback => |expr| {
                        const result = try genExpression(self, expr, .{ .result_loc = .{ .temp_buffer_index = feedback_out_temp_index } }, feedback_temp_index);
                        defer releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
                    },
                }
            }

            try self.instructions.append(.{
                .delay_end = .{
                    .out = out,
                    .feedback_out_temp_buffer_index = feedback_out_temp_index,
                    .delay_index = delay_index,
                },
            });

            return result2;
        },
        .feedback => {
            const feedback_temp_index = maybe_feedback_temp_index orelse {
                return fail(self.source, expression.source_range, "`feedback` can only be used within a `delay` operation", .{});
            };
            return coerce(self, sr, result_info, .{ .temp_buffer_weak = feedback_temp_index });
        },
    }
}

fn genLetAssignment(self: *CodegenState, x: LetAssignment, maybe_feedback_temp_index: ?usize) GenError!void {
    // for now, only buffer type is supported for let-assignments
    // create a "temp" to hold the value
    const temp_buffer_index = try self.temp_buffers.claim();

    // mark the temp to be released at the end of all codegen
    self.local_temps[x.local_index] = temp_buffer_index;

    const result_info: ResultInfo = .{
        .result_loc = .{ .temp_buffer_index = temp_buffer_index },
    };
    const result = try genExpression(self, x.expression, result_info, maybe_feedback_temp_index);
    defer releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
}

pub const CodeGenResult = struct {
    num_outputs: usize,
    num_temps: usize,
    fields: []const Field,
    delays: []const DelayDecl, // owned slice
    instructions: []const Instruction, // owned slice (might need to remove `const` to make it free-able?)
};

// codegen_results is just there so we can read the num_temps of modules being called.
pub fn codegen(
    source: Source,
    codegen_results: []const CodeGenResult,
    first_pass_result: FirstPassResult,
    module_index: usize,
    fields: []const Field,
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
        .fields = fields,
        .locals = locals,
        .instructions = std.ArrayList(Instruction).init(allocator),
        .temp_buffers = TempManager.init(allocator),
        .num_temp_floats = 0,
        .num_temp_bools = 0,
        .local_temps = try allocator.alloc(?usize, locals.len),
        .delays = std.ArrayList(DelayDecl).init(allocator),
    };
    errdefer self.instructions.deinit();
    errdefer self.delays.deinit();
    defer self.temp_buffers.deinit();
    defer allocator.free(self.local_temps);

    std.mem.set(?usize, self.local_temps, null);

    for (scope.statements.span()) |statement| {
        switch (statement) {
            .let_assignment => |x| {
                try genLetAssignment(&self, x, null);
            },
            .output => |expression| {
                const result_info: ResultInfo = .{ .result_loc = .{ .output_index = 0 } };
                const result = try genExpression(&self, expression, result_info, null);
                defer releaseExpressionResult(&self, result); // this should do nothing (because we passed a result loc)
            },
            .feedback => |expression| {
                return fail(source, expression.source_range, "`feedback` can only be used within a `delay` operation", .{});
            },
        }
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
        .fields = fields,
        .delays = self.delays.toOwnedSlice(),
        .instructions = self.instructions.toOwnedSlice(),
    };
}
