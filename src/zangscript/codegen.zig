const std = @import("std");
const Context = @import("context.zig").Context;
const SourceRange = @import("context.zig").SourceRange;
const fail = @import("fail.zig").fail;
const Token = @import("tokenize.zig").Token;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const NumberLiteral = @import("parse.zig").NumberLiteral;
const ParsedModuleInfo = @import("parse.zig").ParsedModuleInfo;
const ParseResult = @import("parse.zig").ParseResult;
const Curve = @import("parse.zig").Curve;
const Module = @import("parse.zig").Module;
const ModuleParam = @import("parse.zig").ModuleParam;
const ParamType = @import("parse.zig").ParamType;
const CallArg = @import("parse.zig").CallArg;
const UnArithOp = @import("parse.zig").UnArithOp;
const BinArithOp = @import("parse.zig").BinArithOp;
const Delay = @import("parse.zig").Delay;
const Field = @import("parse.zig").Field;
const Local = @import("parse.zig").Local;
const Expression = @import("parse.zig").Expression;
const Statement = @import("parse.zig").Statement;
const Scope = @import("parse.zig").Scope;
const BuiltinEnumValue = @import("builtins.zig").BuiltinEnumValue;
const builtins = @import("builtins.zig").builtins;
const printBytecode = @import("codegen_print.zig").printBytecode;

pub const TempRef = struct {
    index: usize, // temp index
    is_weak: bool, // if true, someone else owns the temp, so don't release it

    fn strong(index: usize) TempRef {
        return .{ .index = index, .is_weak = false };
    }

    fn weak(index: usize) TempRef {
        return .{ .index = index, .is_weak = true };
    }
};

// expression will return how it stored its result.
// caller needs to make sure to release it (by calling releaseExpressionResult), which will release any temps that were being used.
pub const ExpressionResult = union(enum) {
    nothing, // this means the result was already written into a result location
    temp_buffer: TempRef,
    temp_float: TempRef,
    curve_ref: usize,
    literal_boolean: bool,
    literal_number: NumberLiteral,
    literal_enum_value: struct { label: []const u8, payload: ?*const ExpressionResult },
    self_param: usize,
};

pub const FloatDest = struct {
    temp_float_index: usize,
};

pub const BufferDest = union(enum) {
    temp_buffer_index: usize,
    output_index: usize,
};

pub const InstrCopyBuffer = struct { out: BufferDest, in: ExpressionResult };
pub const InstrFloatToBuffer = struct { out: BufferDest, in: ExpressionResult };
pub const InstrCobToBuffer = struct { out: BufferDest, in_self_param: usize };
pub const InstrArithFloat = struct { out: FloatDest, op: UnArithOp, a: ExpressionResult };
pub const InstrArithBuffer = struct { out: BufferDest, op: UnArithOp, a: ExpressionResult };
pub const InstrArithFloatFloat = struct { out: FloatDest, op: BinArithOp, a: ExpressionResult, b: ExpressionResult };
pub const InstrArithFloatBuffer = struct { out: BufferDest, op: BinArithOp, a: ExpressionResult, b: ExpressionResult };
pub const InstrArithBufferFloat = struct { out: BufferDest, op: BinArithOp, a: ExpressionResult, b: ExpressionResult };
pub const InstrArithBufferBuffer = struct { out: BufferDest, op: BinArithOp, a: ExpressionResult, b: ExpressionResult };

pub const InstrCall = struct {
    // paint always results in a buffer.
    out: BufferDest,
    // which field of the "self" module we are calling
    field_index: usize,
    // list of temp buffers passed along for the callee's internal use
    temps: []const usize,
    // list of argument param values (in the order of the callee module's params)
    args: []const ExpressionResult,
};

pub const InstrDelay = struct {
    delay_index: usize,
    out: BufferDest,
    feedback_out_temp_buffer_index: usize,
    feedback_temp_buffer_index: usize,
    instructions: []const Instruction,
};

pub const Instruction = union(enum) {
    copy_buffer: InstrCopyBuffer,
    float_to_buffer: InstrFloatToBuffer,
    cob_to_buffer: InstrCobToBuffer,
    arith_float: InstrArithFloat,
    arith_buffer: InstrArithBuffer,
    arith_float_float: InstrArithFloatFloat,
    arith_float_buffer: InstrArithFloatBuffer,
    arith_buffer_float: InstrArithBufferFloat,
    arith_buffer_buffer: InstrArithBufferBuffer,
    call: InstrCall,
    delay: InstrDelay,
};

pub const DelayDecl = struct {
    num_samples: usize,
};

pub const CurrentDelay = struct {
    feedback_temp_index: usize,
    instructions: std.ArrayList(Instruction),
};

pub const CodegenModuleState = struct {
    arena_allocator: *std.mem.Allocator,
    ctx: Context,
    curves: []const Curve,
    modules: []const Module,
    module_results: []const CodeGenModuleResult,
    module_index: usize,
    resolved_fields: []const usize,
    locals: []const Local,
    instructions: std.ArrayList(Instruction),
    temp_buffers: TempManager,
    temp_floats: TempManager,
    local_results: []?ExpressionResult,
    delays: std.ArrayList(DelayDecl),
    current_delay: ?*CurrentDelay,
};

const TempManager = struct {
    reuse_slots: bool,
    slot_claimed: std.ArrayList(bool),

    fn init(allocator: *std.mem.Allocator, reuse_slots: bool) TempManager {
        return .{
            .reuse_slots = reuse_slots,
            .slot_claimed = std.ArrayList(bool).init(allocator),
        };
    }

    fn deinit(self: *TempManager) void {
        self.slot_claimed.deinit();
    }

    fn reportLeaks(self: *const TempManager) void {
        // if we're cleaning up because an error occurred, don't complain
        // about leaks. i don't care about releasing every temp in an
        // error situation.
        var num_leaked: usize = 0;
        for (self.slot_claimed.items) |in_use| {
            if (in_use) num_leaked += 1;
        }
        if (num_leaked > 0) {
            std.debug.warn("error - {} temp(s) leaked in codegen\n", .{num_leaked});
        }
    }

    fn claim(self: *TempManager) !usize {
        if (self.reuse_slots) {
            for (self.slot_claimed.items) |*in_use, index| {
                if (in_use.*) continue;
                in_use.* = true;
                return index;
            }
        }
        const index = self.slot_claimed.items.len;
        try self.slot_claimed.append(true);
        return index;
    }

    fn release(self: *TempManager, index: usize) void {
        std.debug.assert(self.slot_claimed.items[index]);
        self.slot_claimed.items[index] = false;
    }

    pub fn finalCount(self: *const TempManager) usize {
        return self.slot_claimed.items.len;
    }
};

fn releaseExpressionResult(self: *CodegenModuleState, result: ExpressionResult) void {
    switch (result) {
        .temp_buffer => |temp_ref| {
            if (!temp_ref.is_weak) self.temp_buffers.release(temp_ref.index);
        },
        .temp_float => |temp_ref| {
            if (!temp_ref.is_weak) self.temp_floats.release(temp_ref.index);
        },
        .literal_enum_value => |literal| {
            if (literal.payload) |payload| {
                releaseExpressionResult(self, payload.*);
            }
        },
        else => {},
    }
}

fn isResultBoolean(self: *CodegenModuleState, result: ExpressionResult) bool {
    return switch (result) {
        .nothing => unreachable,
        .literal_boolean => true,
        .self_param => |i| self.modules[self.module_index].params[i].param_type == .boolean,
        .literal_number, .literal_enum_value, .temp_buffer, .temp_float, .curve_ref => false,
    };
}

fn isResultFloat(self: *CodegenModuleState, result: ExpressionResult) bool {
    return switch (result) {
        .nothing => unreachable,
        .temp_float, .literal_number => true,
        .self_param => |i| self.modules[self.module_index].params[i].param_type == .constant,
        .literal_boolean, .literal_enum_value, .temp_buffer, .curve_ref => false,
    };
}

fn isResultBuffer(self: *CodegenModuleState, result: ExpressionResult) bool {
    return switch (result) {
        .nothing => unreachable,
        .temp_buffer => true,
        .self_param => |i| self.modules[self.module_index].params[i].param_type == .buffer,
        .temp_float, .literal_boolean, .literal_number, .literal_enum_value, .curve_ref => false,
    };
}

fn isResultCurve(self: *CodegenModuleState, result: ExpressionResult) bool {
    return switch (result) {
        .nothing => unreachable,
        .curve_ref => true,
        .self_param => |i| self.modules[self.module_index].params[i].param_type == .curve,
        .temp_buffer, .temp_float, .literal_boolean, .literal_number, .literal_enum_value => false,
    };
}

fn enumAllowsValue(allowed_values: []const BuiltinEnumValue, label: []const u8, has_float_payload: bool) bool {
    const allowed_value = for (allowed_values) |value| {
        if (std.mem.eql(u8, label, value.label)) break value;
    } else return false;
    return switch (allowed_value.payload_type) {
        .none => !has_float_payload,
        .f32 => has_float_payload,
    };
}

fn isResultEnumValue(self: *CodegenModuleState, result: ExpressionResult, allowed_values: []const BuiltinEnumValue) bool {
    switch (result) {
        .nothing => unreachable,
        .literal_enum_value => |v| {
            const has_float_payload = if (v.payload) |p| isResultFloat(self, p.*) else false;
            return enumAllowsValue(allowed_values, v.label, has_float_payload);
        },
        .self_param => |i| {
            const possible_values = switch (self.modules[self.module_index].params[i].param_type) {
                .one_of => |e| e.values,
                else => return false,
            };
            // each of the possible values must be in the allowed_values
            for (possible_values) |possible_value| {
                const has_float_payload = switch (possible_value.payload_type) {
                    .none => false,
                    .f32 => true,
                };
                if (!enumAllowsValue(allowed_values, possible_value.label, has_float_payload)) return false;
            }
            return true;
        },
        .literal_boolean, .literal_number, .temp_buffer, .temp_float, .curve_ref => return false,
    }
}

// caller wants to return a float-typed result
fn requestFloatDest(self: *CodegenModuleState) !FloatDest {
    // float-typed result locs don't exist for now
    const temp_float_index = try self.temp_floats.claim();
    return FloatDest{ .temp_float_index = temp_float_index };
}

fn commitFloatDest(self: *CodegenModuleState, fd: FloatDest) !ExpressionResult {
    // since result_loc can never be float-typed, just do the simple thing
    return ExpressionResult{ .temp_float = TempRef.strong(fd.temp_float_index) };
}

// caller wants to return a buffer-typed result
fn requestBufferDest(self: *CodegenModuleState, maybe_result_loc: ?BufferDest) !BufferDest {
    if (maybe_result_loc) |result_loc| {
        return result_loc;
    }
    const temp_buffer_index = try self.temp_buffers.claim();
    return BufferDest{ .temp_buffer_index = temp_buffer_index };
}

fn commitBufferDest(self: *CodegenModuleState, maybe_result_loc: ?BufferDest, buffer_dest: BufferDest) !ExpressionResult {
    if (maybe_result_loc != null) {
        return ExpressionResult.nothing;
    }
    const temp_buffer_index = switch (buffer_dest) {
        .temp_buffer_index => |i| i,
        .output_index => unreachable,
    };
    return ExpressionResult{ .temp_buffer = TempRef.strong(temp_buffer_index) };
}

fn addInstruction(self: *CodegenModuleState, instruction: Instruction) !void {
    if (self.current_delay) |current_delay| {
        try current_delay.instructions.append(instruction);
    } else {
        try self.instructions.append(instruction);
    }
}

fn genLiteralEnum(self: *CodegenModuleState, label: []const u8, payload: ?*const Expression) !ExpressionResult {
    if (payload) |payload_expr| {
        const payload_result = try genExpression(self, payload_expr, null);
        // the payload_result is now owned by the enum result, and will be released with it by releaseExpressionResult
        var payload_result_ptr = try self.arena_allocator.create(ExpressionResult);
        payload_result_ptr.* = payload_result;
        return ExpressionResult{ .literal_enum_value = .{ .label = label, .payload = payload_result_ptr } };
    } else {
        return ExpressionResult{ .literal_enum_value = .{ .label = label, .payload = null } };
    }
}

fn genUnArith(self: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, op: UnArithOp, ea: *const Expression) !ExpressionResult {
    const ra = try genExpression(self, ea, null);
    defer releaseExpressionResult(self, ra);

    if (isResultFloat(self, ra)) {
        // float -> float
        const float_dest = try requestFloatDest(self);
        try addInstruction(self, .{ .arith_float = .{ .out = float_dest, .op = op, .a = ra } });
        return commitFloatDest(self, float_dest);
    }
    if (isResultBuffer(self, ra)) {
        // buffer -> buffer
        const buffer_dest = try requestBufferDest(self, maybe_result_loc);
        try addInstruction(self, .{ .arith_buffer = .{ .out = buffer_dest, .op = op, .a = ra } });
        return commitBufferDest(self, maybe_result_loc, buffer_dest);
    }
    return fail(self.ctx, sr, "arithmetic can only be performed on numeric types", .{});
}

fn genBinArith(self: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, op: BinArithOp, ea: *const Expression, eb: *const Expression) !ExpressionResult {
    const ra = try genExpression(self, ea, null);
    defer releaseExpressionResult(self, ra);
    const rb = try genExpression(self, eb, null);
    defer releaseExpressionResult(self, rb);

    if (isResultFloat(self, ra)) {
        if (isResultFloat(self, rb)) {
            // float * float -> float
            const float_dest = try requestFloatDest(self);
            try addInstruction(self, .{ .arith_float_float = .{ .out = float_dest, .op = op, .a = ra, .b = rb } });
            return commitFloatDest(self, float_dest);
        }
        if (isResultBuffer(self, rb)) {
            // float * buffer -> buffer
            const buffer_dest = try requestBufferDest(self, maybe_result_loc);
            try addInstruction(self, .{ .arith_float_buffer = .{ .out = buffer_dest, .op = op, .a = ra, .b = rb } });
            return commitBufferDest(self, maybe_result_loc, buffer_dest);
        }
    }
    if (isResultBuffer(self, ra)) {
        if (isResultFloat(self, rb)) {
            // buffer * float -> buffer
            const buffer_dest = try requestBufferDest(self, maybe_result_loc);
            try addInstruction(self, .{ .arith_buffer_float = .{ .out = buffer_dest, .op = op, .a = ra, .b = rb } });
            return commitBufferDest(self, maybe_result_loc, buffer_dest);
        }
        if (isResultBuffer(self, rb)) {
            // buffer * buffer -> buffer
            const buffer_dest = try requestBufferDest(self, maybe_result_loc);
            try addInstruction(self, .{ .arith_buffer_buffer = .{ .out = buffer_dest, .op = op, .a = ra, .b = rb } });
            return commitBufferDest(self, maybe_result_loc, buffer_dest);
        }
    }
    return fail(self.ctx, sr, "arithmetic can only be performed on numeric types", .{});
}

// typecheck (coercing if possible) and return a value that matches the callee param's type
fn commitCalleeParam(self: *CodegenModuleState, sr: SourceRange, result: ExpressionResult, callee_param_type: ParamType) !ExpressionResult {
    switch (callee_param_type) {
        .boolean => {
            if (isResultBoolean(self, result)) return result;
            return fail(self.ctx, sr, "expected boolean value", .{});
        },
        .buffer => {
            if (isResultBuffer(self, result)) return result;
            if (isResultFloat(self, result)) {
                const temp_buffer_index = try self.temp_buffers.claim();
                try addInstruction(self, .{ .float_to_buffer = .{ .out = .{ .temp_buffer_index = temp_buffer_index }, .in = result } });
                return ExpressionResult{ .temp_buffer = TempRef.strong(temp_buffer_index) };
            }
            return fail(self.ctx, sr, "expected buffer value", .{});
        },
        .constant_or_buffer => {
            if (isResultBuffer(self, result)) return result;
            if (isResultFloat(self, result)) return result;
            return fail(self.ctx, sr, "expected float or buffer value", .{});
        },
        .constant => {
            if (isResultFloat(self, result)) return result;
            return fail(self.ctx, sr, "expected float value", .{});
        },
        .curve => {
            if (isResultCurve(self, result)) return result;
            return fail(self.ctx, sr, "expected curve value", .{});
        },
        .one_of => |e| {
            if (isResultEnumValue(self, result, e.values)) return result;
            return fail(self.ctx, sr, "expected one of |", .{e.values});
        },
    }
}

// crippled version of commitCalleeParam used by tracks (there is no module present
// and therefore we can't generate instructions)
fn commitCalleeParamLiteral(ctx: Context, sr: SourceRange, result: ExpressionResult, callee_param_type: ParamType) !ExpressionResult {
    switch (callee_param_type) {
        .boolean => switch (result) {
            .literal_boolean => return result,
            else => return fail(ctx, sr, "expected boolean value", .{}),
        },
        .constant => switch (result) {
            .literal_number => return result,
            else => return fail(ctx, sr, "expected float value", .{}),
        },
        //.one_of => |e| {
        //    if (isResultEnumValue(self, result, e.values)) return result;
        //    return fail(ctx, sr, "expected one of |", .{e.values});
        //},
        else => return fail(ctx, sr, "unsupported param type (not implemented)", .{}),
    }
}
fn genCurveRef(self: *CodegenModuleState, token: Token) !ExpressionResult {
    const curve_name = self.ctx.source.getString(token.source_range);
    const index = for (self.curves) |curve, i| {
        if (std.mem.eql(u8, curve.name, curve_name)) break i;
    } else return fail(self.ctx, token.source_range, "curve `<` does not exist", .{});
    return ExpressionResult{ .curve_ref = index };
}

fn genCall(self: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, field_index: usize, args: []const CallArg) !ExpressionResult {
    const field_module_index = self.resolved_fields[field_index];
    const callee_module = self.modules[field_module_index];
    const callee_num_temps = self.module_results[field_module_index].num_temps;

    // pass params
    for (args) |a| {
        for (callee_module.params) |param| {
            if (std.mem.eql(u8, a.param_name, param.name)) break;
        } else return fail(self.ctx, a.param_name_token.source_range, "module `#` has no param called `<`", .{callee_module.name});
    }
    var arg_results = try self.arena_allocator.alloc(ExpressionResult, callee_module.params.len);
    for (callee_module.params) |param, i| {
        // find this arg in the call node
        var maybe_arg: ?CallArg = null;
        for (args) |a| {
            if (!std.mem.eql(u8, a.param_name, param.name)) continue;
            if (maybe_arg != null) return fail(self.ctx, a.param_name_token.source_range, "param `<` provided more than once", .{});
            maybe_arg = a;
        }
        if (maybe_arg == null and std.mem.eql(u8, param.name, "sample_rate")) {
            // sample_rate is passed implicitly
            const self_param_index = for (self.modules[self.module_index].params) |self_param, j| {
                if (std.mem.eql(u8, self_param.name, "sample_rate")) break j;
            } else unreachable;
            arg_results[i] = .{ .self_param = self_param_index };
            continue;
        }
        const arg = maybe_arg orelse return fail(self.ctx, sr, "call is missing param `#`", .{param.name});
        const result = try genExpression(self, arg.value, null);
        arg_results[i] = try commitCalleeParam(self, arg.value.source_range, result, param.param_type);
    }
    defer for (callee_module.params) |param, i| releaseExpressionResult(self, arg_results[i]);

    // the callee needs temps for its own internal use
    var temps = try self.arena_allocator.alloc(usize, callee_num_temps);
    for (temps) |*ptr| ptr.* = try self.temp_buffers.claim();
    defer for (temps) |temp_buffer_index| self.temp_buffers.release(temp_buffer_index);

    const buffer_dest = try requestBufferDest(self, maybe_result_loc);
    try addInstruction(self, .{
        .call = .{
            .out = buffer_dest,
            .field_index = field_index,
            .temps = temps,
            .args = arg_results,
        },
    });
    return commitBufferDest(self, maybe_result_loc, buffer_dest);
}

fn genDelay(self: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, delay: Delay) !ExpressionResult {
    if (self.current_delay != null) {
        return fail(self.ctx, sr, "you cannot nest delay operations", .{}); // i might be able to support this, but why?
    }

    const delay_index = self.delays.items.len;
    try self.delays.append(.{ .num_samples = delay.num_samples });

    const feedback_temp_index = try self.temp_buffers.claim();
    defer self.temp_buffers.release(feedback_temp_index);

    const buffer_dest = try requestBufferDest(self, maybe_result_loc);

    const feedback_out_temp_index = try self.temp_buffers.claim();
    defer self.temp_buffers.release(feedback_out_temp_index);

    var current_delay: CurrentDelay = .{
        .feedback_temp_index = feedback_temp_index,
        .instructions = std.ArrayList(Instruction).init(self.arena_allocator),
    };

    self.current_delay = &current_delay;

    for (delay.scope.statements.items) |statement| {
        switch (statement) {
            .let_assignment => |x| {
                self.local_results[x.local_index] = try genExpression(self, x.expression, null);
            },
            .output => |expr| {
                const result = try genExpression(self, expr, buffer_dest);
                try commitOutput(self, expr.source_range, result, buffer_dest);
                releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
            },
            .feedback => |expr| {
                const result_loc: BufferDest = .{ .temp_buffer_index = feedback_out_temp_index };
                const result = try genExpression(self, expr, result_loc);
                try commitOutput(self, expr.source_range, result, result_loc);
                releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
            },
        }
    }

    self.current_delay = null;

    try addInstruction(self, .{
        .delay = .{
            .out = buffer_dest,
            .delay_index = delay_index,
            .feedback_out_temp_buffer_index = feedback_out_temp_index,
            .feedback_temp_buffer_index = feedback_temp_index, // do i need this?
            .instructions = current_delay.instructions.toOwnedSlice(),
        },
    });

    return commitBufferDest(self, maybe_result_loc, buffer_dest);
}

pub const GenError = error{
    Failed,
    OutOfMemory,
};

// crippled version of genExpression which only works on literals. used for track definitions
// (when there is no active module and thus no instructions)
fn genLiteral(ctx: Context, arena_allocator: *std.mem.Allocator, expr: *const Expression) !ExpressionResult {
    const sr = expr.source_range;

    switch (expr.inner) {
        //.curve_ref => |token| return genCurveRef(self, token), // TODO
        .literal_boolean => |value| return ExpressionResult{ .literal_boolean = value },
        .literal_number => |value| return ExpressionResult{ .literal_number = value },
        //.literal_enum_value => |v| return genLiteralEnum(self, v.label, v.payload), // TODO
        else => return fail(ctx, sr, "expected a literal value", .{}),
    }
}

// generate bytecode instructions for an expression
fn genExpression(self: *CodegenModuleState, expression: *const Expression, maybe_result_loc: ?BufferDest) GenError!ExpressionResult {
    const sr = expression.source_range;

    switch (expression.inner) {
        .curve_ref => |token| return genCurveRef(self, token),
        .literal_boolean => |value| return ExpressionResult{ .literal_boolean = value },
        .literal_number => |value| return ExpressionResult{ .literal_number = value },
        .literal_enum_value => |v| return genLiteralEnum(self, v.label, v.payload),
        .local => |local_index| {
            // a local is just a saved ExpressionResult. make a weak-reference version of it
            const result = self.local_results[local_index].?;
            switch (result) {
                .temp_buffer => |temp_ref| return ExpressionResult{ .temp_buffer = TempRef.weak(temp_ref.index) },
                .temp_float => |temp_ref| return ExpressionResult{ .temp_float = TempRef.weak(temp_ref.index) },
                else => return result,
            }
        },
        .self_param => |param_index| {
            // immediately turn constant_or_buffer into buffer (the rest of codegen isn't able to work with constant_or_buffer)
            if (self.modules[self.module_index].params[param_index].param_type == .constant_or_buffer) {
                const buffer_dest = try requestBufferDest(self, maybe_result_loc);
                try addInstruction(self, .{ .cob_to_buffer = .{ .out = buffer_dest, .in_self_param = param_index } });
                return try commitBufferDest(self, maybe_result_loc, buffer_dest);
            } else {
                return ExpressionResult{ .self_param = param_index };
            }
        },
        .un_arith => |m| return try genUnArith(self, sr, maybe_result_loc, m.op, m.a),
        .bin_arith => |m| return try genBinArith(self, sr, maybe_result_loc, m.op, m.a, m.b),
        .call => |call| return try genCall(self, sr, maybe_result_loc, call.field_index, call.args),
        .delay => |delay| return try genDelay(self, sr, maybe_result_loc, delay),
        .feedback => {
            const feedback_temp_index = if (self.current_delay) |current_delay|
                current_delay.feedback_temp_index
            else
                return fail(self.ctx, expression.source_range, "`feedback` can only be used within a `delay` operation", .{});
            return ExpressionResult{ .temp_buffer = TempRef.weak(feedback_temp_index) };
        },
    }
}

// typecheck and make sure that the expression result is written into buffer_dest.
fn commitOutput(self: *CodegenModuleState, sr: SourceRange, result: ExpressionResult, buffer_dest: BufferDest) !void {
    switch (result) {
        .nothing => {
            // value has already been written into the result location
        },
        .temp_buffer => {
            try addInstruction(self, .{ .copy_buffer = .{ .out = buffer_dest, .in = result } });
        },
        .temp_float, .literal_number => {
            try addInstruction(self, .{ .float_to_buffer = .{ .out = buffer_dest, .in = result } });
        },
        .literal_boolean => return fail(self.ctx, sr, "expected buffer value, found boolean", .{}),
        .literal_enum_value => return fail(self.ctx, sr, "expected buffer value, found enum value", .{}),
        .curve_ref => return fail(self.ctx, sr, "expected buffer value, found curve", .{}),
        .self_param => |param_index| {
            switch (self.modules[self.module_index].params[param_index].param_type) {
                .boolean => return fail(self.ctx, sr, "expected buffer value, found boolean", .{}),
                .buffer, .constant_or_buffer => { // constant_or_buffer are immediately unwrapped to buffers in codegen (for now)
                    try addInstruction(self, .{ .copy_buffer = .{ .out = buffer_dest, .in = .{ .self_param = param_index } } });
                },
                .constant => {
                    try addInstruction(self, .{ .float_to_buffer = .{ .out = buffer_dest, .in = .{ .self_param = param_index } } });
                },
                .curve => return fail(self.ctx, sr, "expected buffer value, found curve", .{}),
                .one_of => |e| return fail(self.ctx, sr, "expected buffer value, found enum value", .{}),
            }
        },
    }
}

fn genTopLevelStatement(self: *CodegenModuleState, statement: Statement) !void {
    std.debug.assert(self.current_delay == null);

    switch (statement) {
        .let_assignment => |x| {
            self.local_results[x.local_index] = try genExpression(self, x.expression, null);
        },
        .output => |expression| {
            const result_loc: BufferDest = .{ .output_index = 0 };
            const result = try genExpression(self, expression, result_loc);
            try commitOutput(self, expression.source_range, result, result_loc);
            releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
        },
        .feedback => |expression| {
            return fail(self.ctx, expression.source_range, "`feedback` can only be used within a `delay` operation", .{});
        },
    }
}

pub const CodeGenTrackResult = struct {
    note_values: []const []const ExpressionResult, // values in order of track params
};

pub const CodeGenCustomModuleInner = struct {
    resolved_fields: []const usize, // owned slice
    delays: []const DelayDecl, // owned slice
    instructions: []const Instruction, // owned slice
};

pub const CodeGenModuleResult = struct {
    num_outputs: usize,
    num_temps: usize,
    num_temp_floats: usize,
    inner: union(enum) {
        builtin,
        custom: CodeGenCustomModuleInner,
    },
};

pub const CodeGenResult = struct {
    arena: std.heap.ArenaAllocator,
    track_results: []const CodeGenTrackResult,
    module_results: []const CodeGenModuleResult,

    pub fn deinit(self: *CodeGenResult) void {
        self.arena.deinit();
    }
};

// visit codegen modules in dependency order (modules need to know the
// `num_temps` of their fields, which is resolved during codegen)
const CodeGenVisitor = struct {
    arena_allocator: *std.mem.Allocator, // for persistent allocations (used in result)
    inner_allocator: *std.mem.Allocator, // for temporary allocations
    ctx: Context,
    parse_result: ParseResult,
    module_results: []CodeGenModuleResult, // filled in as we go
    module_visited: []bool, // ditto
    dump_codegen_out: ?std.io.StreamSource.OutStream,
};

// codegen entry point
pub fn codegen(
    ctx: Context,
    parse_result: ParseResult,
    inner_allocator: *std.mem.Allocator,
    dump_codegen_out: ?std.io.StreamSource.OutStream,
) !CodeGenResult {
    var arena = std.heap.ArenaAllocator.init(inner_allocator);
    errdefer arena.deinit();

    // tracks
    var track_results = try arena.allocator.alloc(CodeGenTrackResult, parse_result.tracks.len);
    for (parse_result.tracks) |track, track_index| {
        var notes = try arena.allocator.alloc([]const ExpressionResult, track.notes.len);
        for (track.notes) |note, note_index| {
            for (note.args) |a| {
                for (track.params) |param| {
                    if (std.mem.eql(u8, a.param_name, param.name)) break;
                } else return fail(ctx, a.param_name_token.source_range, "track `#` has no param called `<`", .{track.name});
            }
            var arg_results = try arena.allocator.alloc(ExpressionResult, track.params.len);
            for (track.params) |param, i| {
                // find this arg in the call node
                var maybe_arg: ?CallArg = null;
                for (note.args) |a| {
                    if (!std.mem.eql(u8, a.param_name, param.name)) continue;
                    if (maybe_arg != null) return fail(ctx, a.param_name_token.source_range, "param `<` provided more than once", .{});
                    maybe_arg = a;
                }
                const arg = maybe_arg orelse return fail(ctx, note.args_source_range, "track note is missing param `#`", .{param.name});
                const result = try genLiteral(ctx, &arena.allocator, arg.value);
                arg_results[i] = try commitCalleeParamLiteral(ctx, arg.value.source_range, result, param.param_type);
            }
            notes[note_index] = arg_results;
        }
        track_results[track_index] = .{
            .note_values = notes,
        };
    }

    // modules
    var module_visited = try inner_allocator.alloc(bool, parse_result.modules.len);
    defer inner_allocator.free(module_visited);

    std.mem.set(bool, module_visited, false);

    var module_results = try arena.allocator.alloc(CodeGenModuleResult, parse_result.modules.len);

    var builtin_index: usize = 0;
    for (ctx.builtin_packages) |pkg| {
        for (pkg.builtins) |builtin| {
            module_results[builtin_index] = .{
                .num_outputs = builtin.num_outputs,
                .num_temps = builtin.num_temps,
                .num_temp_floats = 0,
                .inner = .builtin,
            };
            module_visited[builtin_index] = true;
            builtin_index += 1;
        }
    }

    var self: CodeGenVisitor = .{
        .arena_allocator = &arena.allocator,
        .inner_allocator = inner_allocator,
        .ctx = ctx,
        .parse_result = parse_result,
        .module_results = module_results,
        .module_visited = module_visited,
        .dump_codegen_out = dump_codegen_out,
    };

    for (parse_result.modules) |_, i| {
        try visitModule(&self, i, i);
    }

    return CodeGenResult{
        .arena = arena,
        .track_results = track_results,
        .module_results = module_results,
    };
}

fn visitModule(self: *CodeGenVisitor, self_module_index: usize, module_index: usize) GenError!void {
    if (self.module_visited[module_index]) {
        return;
    }
    self.module_visited[module_index] = true;

    const module_info = self.parse_result.modules[module_index].info.?;

    // first, recursively resolve all modules that this one uses as its fields
    var resolved_fields = try self.arena_allocator.alloc(usize, module_info.fields.len);

    for (module_info.fields) |field, field_index| {
        // find the module index for this field name
        const field_name = self.ctx.source.getString(field.type_token.source_range);
        const resolved_module_index = for (self.parse_result.modules) |m, i| {
            if (std.mem.eql(u8, field_name, m.name)) {
                break i;
            }
        } else {
            return fail(self.ctx, field.type_token.source_range, "no module called `<`", .{});
        };

        // check for dependency loops and then recurse
        if (resolved_module_index == self_module_index) {
            return fail(self.ctx, field.type_token.source_range, "circular dependency in module fields", .{});
        }
        try visitModule(self, self_module_index, resolved_module_index);

        // ok
        resolved_fields[field_index] = resolved_module_index;
    }

    // now resolve this one
    self.module_results[module_index] = try codegenModule(self, module_index, module_info, resolved_fields);
}

fn codegenModule(self: *CodeGenVisitor, module_index: usize, module_info: ParsedModuleInfo, resolved_fields: []const usize) !CodeGenModuleResult {
    var state: CodegenModuleState = .{
        .arena_allocator = self.arena_allocator,
        .ctx = self.ctx,
        .curves = self.parse_result.curves,
        .modules = self.parse_result.modules,
        .module_results = self.module_results,
        .module_index = module_index,
        .resolved_fields = resolved_fields,
        .locals = module_info.locals,
        .instructions = std.ArrayList(Instruction).init(self.arena_allocator),
        .temp_buffers = TempManager.init(self.inner_allocator, true),
        // pass false: don't reuse temp floats slots (they become `const` in zig)
        // TODO we could reuse them if we're targeting runtime, not codegen_zig
        .temp_floats = TempManager.init(self.inner_allocator, false),
        .local_results = try self.arena_allocator.alloc(?ExpressionResult, module_info.locals.len),
        .delays = std.ArrayList(DelayDecl).init(self.arena_allocator),
        .current_delay = null,
    };
    defer state.temp_buffers.deinit();
    defer state.temp_floats.deinit();

    std.mem.set(?ExpressionResult, state.local_results, null);

    for (module_info.scope.statements.items) |statement| {
        try genTopLevelStatement(&state, statement);
    }

    for (state.local_results) |maybe_result| {
        const result = maybe_result orelse continue;
        releaseExpressionResult(&state, result);
    }

    state.temp_buffers.reportLeaks();
    state.temp_floats.reportLeaks();

    if (self.dump_codegen_out) |out| {
        printBytecode(out, &state) catch |err| std.debug.warn("printBytecode failed: {}\n", .{err});
    }

    return CodeGenModuleResult{
        .num_outputs = 1,
        .num_temps = state.temp_buffers.finalCount(),
        .num_temp_floats = state.temp_floats.finalCount(),
        .inner = .{
            .custom = .{
                .resolved_fields = resolved_fields,
                .delays = state.delays.toOwnedSlice(),
                .instructions = state.instructions.toOwnedSlice(),
            },
        },
    };
}
