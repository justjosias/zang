const std = @import("std");
const Source = @import("tokenize.zig").Source;
const SourceRange = @import("tokenize.zig").SourceRange;
const fail = @import("fail.zig").fail;
const ParsedModuleInfo = @import("parse.zig").ParsedModuleInfo;
const ParseResult = @import("parse.zig").ParseResult;
const Module = @import("parse.zig").Module;
const ModuleParam = @import("parse.zig").ModuleParam;
const ParamType = @import("parse.zig").ParamType;
const CallArg = @import("parse.zig").CallArg;
const BinArithOp = @import("parse.zig").BinArithOp;
const Delay = @import("parse.zig").Delay;
const Field = @import("parse.zig").Field;
const Local = @import("parse.zig").Local;
const Expression = @import("parse.zig").Expression;
const Statement = @import("parse.zig").Statement;
const Scope = @import("parse.zig").Scope;
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
    literal_boolean: bool,
    literal_number: f32,
    literal_enum_value: []const u8,
    self_param: usize,
};

pub const BooleanValue = union(enum) {
    self_param: usize, // guaranteed to be of type `boolean`
    literal: bool,
};

pub const FloatDest = struct {
    temp_float_index: usize,
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

pub const EnumValue = union(enum) {
    self_param: usize, // guaranteed to be of an enum type that includes all possible values of the destination enum
    literal: []const u8,
};

pub const Instruction = union(enum) {
    copy_buffer: struct { out: BufferDest, in: BufferValue },
    float_to_buffer: struct { out: BufferDest, in: FloatValue },
    cob_to_buffer: struct { out: BufferDest, in_self_param: usize },
    negate_float_to_float: struct { out: FloatDest, a: FloatValue },
    negate_buffer_to_buffer: struct { out: BufferDest, a: BufferValue },
    arith_float_float: struct { out: FloatDest, op: BinArithOp, a: FloatValue, b: FloatValue },
    arith_float_buffer: struct { out: BufferDest, op: BinArithOp, a: FloatValue, b: BufferValue },
    arith_buffer_float: struct { out: BufferDest, op: BinArithOp, a: BufferValue, b: FloatValue },
    arith_buffer_buffer: struct { out: BufferDest, op: BinArithOp, a: BufferValue, b: BufferValue },
    // call one of self's fields (paint the child module)
    call: struct {
        // paint always results in a buffer.
        out: BufferDest,
        // which field of the "self" module we are calling
        field_index: usize,
        // list of temp buffers passed along for the callee's internal use
        temps: []const usize,
        // list of argument param values (in the order of the callee module's params)
        args: []const ExpressionResult,
    },
    // i might consider replacing this begin/end pair with a single InstrDelay
    // which actually contains a sublist of Instructions?
    delay_begin: struct {
        delay_index: usize,
        out: BufferDest,
        feedback_out_temp_buffer_index: usize,
        feedback_temp_buffer_index: usize,
    },
    delay_end: struct {
        delay_index: usize,
        out: BufferDest,
        feedback_out_temp_buffer_index: usize,
    },
};

pub const DelayDecl = struct {
    num_samples: usize,
};

pub const CodegenModuleState = struct {
    arena_allocator: *std.mem.Allocator,
    source: Source,
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

    fn finalCount(self: *const TempManager) usize {
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
        else => {},
    }
}

fn getResultAsBoolean(self: *CodegenModuleState, result: ExpressionResult) ?BooleanValue {
    return switch (result) {
        .nothing => unreachable,
        .literal_boolean => |value| BooleanValue{ .literal = value },
        .self_param => |i| if (self.modules[self.module_index].params[i].param_type == .boolean)
            BooleanValue{ .self_param = i }
        else
            null,
        .literal_number, .literal_enum_value, .temp_buffer, .temp_float => null,
    };
}

fn getResultAsFloat(self: *CodegenModuleState, result: ExpressionResult) ?FloatValue {
    return switch (result) {
        .nothing => unreachable,
        .temp_float => |temp_ref| FloatValue{ .temp_float_index = temp_ref.index },
        .self_param => |i| if (self.modules[self.module_index].params[i].param_type == .constant)
            FloatValue{ .self_param = i }
        else
            null,
        .literal_number => |value| FloatValue{ .literal = value },
        .literal_boolean, .literal_enum_value, .temp_buffer => null,
    };
}

fn getResultAsBuffer(self: *CodegenModuleState, result: ExpressionResult) ?BufferValue {
    return switch (result) {
        .nothing => unreachable,
        .temp_buffer => |temp_ref| BufferValue{ .temp_buffer_index = temp_ref.index },
        .self_param => |i| if (self.modules[self.module_index].params[i].param_type == .buffer)
            BufferValue{ .self_param = i }
        else
            null,
        .temp_float, .literal_boolean, .literal_number, .literal_enum_value => null,
    };
}

fn enumAllowsValue(allowed_values: []const []const u8, value: []const u8) bool {
    for (allowed_values) |v| {
        if (std.mem.eql(u8, v, value)) {
            return true;
        }
    }
    return false;
}

fn enumAllowsValues(allowed_values: []const []const u8, values: []const []const u8) bool {
    for (values) |value| {
        if (!enumAllowsValue(allowed_values, value)) {
            return false;
        }
    }
    return true;
}

fn getResultAsEnumValue(self: *CodegenModuleState, result: ExpressionResult, allowed_values: []const []const u8) ?EnumValue {
    switch (result) {
        .nothing => unreachable,
        .literal_enum_value => |value| {
            const ok = enumAllowsValue(allowed_values, value);
            return if (ok) EnumValue{ .literal = value } else null;
        },
        .self_param => |i| {
            const ok = switch (self.modules[self.module_index].params[i].param_type) {
                .one_of => |e| enumAllowsValues(allowed_values, e.values),
                else => false,
            };
            return if (ok) EnumValue{ .self_param = i } else null;
        },
        .literal_boolean, .literal_number, .temp_buffer, .temp_float => return null,
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

fn genNegate(self: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, expr: *const Expression, maybe_feedback_temp_index: ?usize) !ExpressionResult {
    const ra = try genExpression(self, expr, null, maybe_feedback_temp_index);
    defer releaseExpressionResult(self, ra);

    if (getResultAsFloat(self, ra)) |a| {
        // float -> float
        const float_dest = try requestFloatDest(self);
        try self.instructions.append(.{ .negate_float_to_float = .{ .out = float_dest, .a = a } });
        return commitFloatDest(self, float_dest);
    }
    if (getResultAsBuffer(self, ra)) |a| {
        // buffer -> buffer
        const buffer_dest = try requestBufferDest(self, maybe_result_loc);
        try self.instructions.append(.{ .negate_buffer_to_buffer = .{ .out = buffer_dest, .a = a } });
        return commitBufferDest(self, maybe_result_loc, buffer_dest);
    }
    return fail(self.source, expr.source_range, "arithmetic can only be performed on numeric types", .{});
}

fn genBinArith(self: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, op: BinArithOp, ea: *const Expression, eb: *const Expression, maybe_feedback_temp_index: ?usize) !ExpressionResult {
    const ra = try genExpression(self, ea, null, maybe_feedback_temp_index);
    defer releaseExpressionResult(self, ra);
    const rb = try genExpression(self, eb, null, maybe_feedback_temp_index);
    defer releaseExpressionResult(self, rb);

    if (getResultAsFloat(self, ra)) |a| {
        if (getResultAsFloat(self, rb)) |b| {
            // float * float -> float
            const float_dest = try requestFloatDest(self);
            try self.instructions.append(.{ .arith_float_float = .{ .out = float_dest, .op = op, .a = a, .b = b } });
            return commitFloatDest(self, float_dest);
        }
        if (getResultAsBuffer(self, rb)) |b| {
            // float * buffer -> buffer
            const buffer_dest = try requestBufferDest(self, maybe_result_loc);
            try self.instructions.append(.{ .arith_float_buffer = .{ .out = buffer_dest, .op = op, .a = a, .b = b } });
            return commitBufferDest(self, maybe_result_loc, buffer_dest);
        }
    }
    if (getResultAsBuffer(self, ra)) |a| {
        if (getResultAsFloat(self, rb)) |b| {
            // buffer * float -> buffer
            const buffer_dest = try requestBufferDest(self, maybe_result_loc);
            try self.instructions.append(.{ .arith_buffer_float = .{ .out = buffer_dest, .op = op, .a = a, .b = b } });
            return commitBufferDest(self, maybe_result_loc, buffer_dest);
        }
        if (getResultAsBuffer(self, rb)) |b| {
            // buffer * buffer -> buffer
            const buffer_dest = try requestBufferDest(self, maybe_result_loc);
            try self.instructions.append(.{ .arith_buffer_buffer = .{ .out = buffer_dest, .op = op, .a = a, .b = b } });
            return commitBufferDest(self, maybe_result_loc, buffer_dest);
        }
    }
    return fail(self.source, sr, "arithmetic can only be performed on numeric types", .{});
}

// typecheck (coercing if possible) and return a value that matches the callee param's type
fn commitCalleeParam(self: *CodegenModuleState, sr: SourceRange, result: ExpressionResult, callee_param_type: ParamType) !ExpressionResult {
    switch (callee_param_type) {
        .boolean => {
            if (getResultAsBoolean(self, result) != null) return result;
            return fail(self.source, sr, "expected boolean value", .{});
        },
        .buffer => {
            if (getResultAsBuffer(self, result) != null) return result;
            if (getResultAsFloat(self, result)) |float_value| {
                const temp_buffer_index = try self.temp_buffers.claim();
                try self.instructions.append(.{ .float_to_buffer = .{ .out = .{ .temp_buffer_index = temp_buffer_index }, .in = float_value } });
                return ExpressionResult{ .temp_buffer = TempRef.strong(temp_buffer_index) };
            }
            return fail(self.source, sr, "expected buffer value", .{});
        },
        .constant_or_buffer => {
            // codegen_zig will wrap for cob types
            if (getResultAsBuffer(self, result) != null) return result;
            if (getResultAsFloat(self, result) != null) return result;
            return fail(self.source, sr, "expected float or buffer value", .{});
        },
        .constant => {
            if (getResultAsFloat(self, result) != null) return result;
            return fail(self.source, sr, "expected float value", .{});
        },
        .one_of => |e| {
            if (getResultAsEnumValue(self, result, e.values) != null) return result;
            return fail(self.source, sr, "expected one of |", .{e.values});
        },
    }
}

fn genCall(self: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, field_index: usize, args: []const CallArg, maybe_feedback_temp_index: ?usize) !ExpressionResult {
    const field_module_index = self.resolved_fields[field_index];
    const callee_module = self.modules[field_module_index];
    const callee_num_temps = self.module_results[field_module_index].num_temps;

    // pass params
    for (args) |a| {
        for (callee_module.params) |param| {
            if (std.mem.eql(u8, a.param_name, param.name)) break;
        } else return fail(self.source, a.param_name_token.source_range, "module `#` has no param called `<`", .{callee_module.name});
    }
    var arg_results = try self.arena_allocator.alloc(ExpressionResult, callee_module.params.len);
    for (callee_module.params) |param, i| {
        // find this arg in the call node
        var maybe_arg: ?CallArg = null;
        for (args) |a| {
            if (!std.mem.eql(u8, a.param_name, param.name)) continue;
            if (maybe_arg != null) return fail(self.source, a.param_name_token.source_range, "param `<` provided more than once", .{});
            maybe_arg = a;
        }
        const arg = maybe_arg orelse return fail(self.source, sr, "call is missing param `#`", .{param.name});
        const result = try genExpression(self, arg.value, null, maybe_feedback_temp_index);
        arg_results[i] = try commitCalleeParam(self, arg.value.source_range, result, param.param_type);
    }
    defer for (callee_module.params) |param, i| releaseExpressionResult(self, arg_results[i]);

    // the callee needs temps for its own internal use
    var temps = try self.arena_allocator.alloc(usize, callee_num_temps);
    for (temps) |*ptr| ptr.* = try self.temp_buffers.claim();
    defer for (temps) |temp_buffer_index| self.temp_buffers.release(temp_buffer_index);

    const buffer_dest = try requestBufferDest(self, maybe_result_loc);
    try self.instructions.append(.{
        .call = .{
            .out = buffer_dest,
            .field_index = field_index,
            .temps = temps,
            .args = arg_results,
        },
    });
    return commitBufferDest(self, maybe_result_loc, buffer_dest);
}

fn genDelay(self: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, delay: Delay, maybe_feedback_temp_index: ?usize) !ExpressionResult {
    if (maybe_feedback_temp_index != null) {
        return fail(self.source, sr, "you cannot nest delay operations", .{}); // i might be able to support this, but why?
    }

    const delay_index = self.delays.items.len;
    try self.delays.append(.{ .num_samples = delay.num_samples });

    const feedback_temp_index = try self.temp_buffers.claim();
    defer self.temp_buffers.release(feedback_temp_index);

    const buffer_dest = try requestBufferDest(self, maybe_result_loc);

    const feedback_out_temp_index = try self.temp_buffers.claim();
    defer self.temp_buffers.release(feedback_out_temp_index);

    try self.instructions.append(.{
        .delay_begin = .{
            .out = buffer_dest,
            .delay_index = delay_index,
            .feedback_out_temp_buffer_index = feedback_out_temp_index,
            .feedback_temp_buffer_index = feedback_temp_index, // do i need this?
        },
    });

    for (delay.scope.statements.items) |statement| {
        switch (statement) {
            .let_assignment => |x| {
                self.local_results[x.local_index] = try genExpression(self, x.expression, null, feedback_temp_index);
            },
            .output => |expr| {
                const result = try genExpression(self, expr, buffer_dest, feedback_temp_index);
                try commitOutput(self, expr.source_range, result, buffer_dest);
                releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
            },
            .feedback => |expr| {
                const result_loc: BufferDest = .{ .temp_buffer_index = feedback_out_temp_index };
                const result = try genExpression(self, expr, result_loc, feedback_temp_index);
                try commitOutput(self, expr.source_range, result, result_loc);
                releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
            },
        }
    }

    try self.instructions.append(.{
        .delay_end = .{
            .out = buffer_dest,
            .feedback_out_temp_buffer_index = feedback_out_temp_index,
            .delay_index = delay_index,
        },
    });

    return commitBufferDest(self, maybe_result_loc, buffer_dest);
}

pub const GenError = error{
    Failed,
    OutOfMemory,
};

// generate bytecode instructions for an expression
fn genExpression(self: *CodegenModuleState, expression: *const Expression, maybe_result_loc: ?BufferDest, maybe_feedback_temp_index: ?usize) GenError!ExpressionResult {
    const sr = expression.source_range;

    switch (expression.inner) {
        .literal_boolean => |value| return ExpressionResult{ .literal_boolean = value },
        .literal_number => |value| return ExpressionResult{ .literal_number = value },
        .literal_enum_value => |value| return ExpressionResult{ .literal_enum_value = value },
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
                try self.instructions.append(.{ .cob_to_buffer = .{ .out = buffer_dest, .in_self_param = param_index } });
                return try commitBufferDest(self, maybe_result_loc, buffer_dest);
            } else {
                return ExpressionResult{ .self_param = param_index };
            }
        },
        .negate => |expr| return try genNegate(self, sr, maybe_result_loc, expr, maybe_feedback_temp_index),
        .bin_arith => |m| return try genBinArith(self, sr, maybe_result_loc, m.op, m.a, m.b, maybe_feedback_temp_index),
        .call => |call| return try genCall(self, sr, maybe_result_loc, call.field_index, call.args, maybe_feedback_temp_index),
        .delay => |delay| return try genDelay(self, sr, maybe_result_loc, delay, maybe_feedback_temp_index),
        .feedback => {
            const feedback_temp_index = maybe_feedback_temp_index orelse {
                return fail(self.source, expression.source_range, "`feedback` can only be used within a `delay` operation", .{});
            };
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
        .temp_buffer => |temp_ref| {
            try self.instructions.append(.{ .copy_buffer = .{ .out = buffer_dest, .in = .{ .temp_buffer_index = temp_ref.index } } });
        },
        .temp_float => |temp_ref| {
            try self.instructions.append(.{ .float_to_buffer = .{ .out = buffer_dest, .in = .{ .temp_float_index = temp_ref.index } } });
        },
        .literal_number => |value| {
            try self.instructions.append(.{ .float_to_buffer = .{ .out = buffer_dest, .in = .{ .literal = value } } });
        },
        .literal_boolean => return fail(self.source, sr, "expected buffer value, found boolean", .{}),
        .literal_enum_value => return fail(self.source, sr, "expected buffer value, found enum value", .{}),
        .self_param => |param_index| {
            switch (self.modules[self.module_index].params[param_index].param_type) {
                .boolean => return fail(self.source, sr, "expected buffer value, found boolean", .{}),
                .buffer, .constant_or_buffer => { // codegen_zig will wrap for cob types
                    try self.instructions.append(.{ .copy_buffer = .{ .out = buffer_dest, .in = .{ .self_param = param_index } } });
                },
                .constant => {
                    try self.instructions.append(.{ .float_to_buffer = .{ .out = buffer_dest, .in = .{ .self_param = param_index } } });
                },
                .one_of => |e| return fail(self.source, sr, "expected buffer value, found enum value", .{}),
            }
        },
    }
}

fn genTopLevelStatement(self: *CodegenModuleState, statement: Statement) !void {
    switch (statement) {
        .let_assignment => |x| {
            self.local_results[x.local_index] = try genExpression(self, x.expression, null, null);
        },
        .output => |expression| {
            const result_loc: BufferDest = .{ .output_index = 0 };
            const result = try genExpression(self, expression, result_loc, null);
            try commitOutput(self, expression.source_range, result, result_loc);
            releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
        },
        .feedback => |expression| {
            return fail(self.source, expression.source_range, "`feedback` can only be used within a `delay` operation", .{});
        },
    }
}

pub const CodeGenModuleResult = struct {
    num_outputs: usize,
    num_temps: usize,
    inner: union(enum) {
        builtin,
        custom: struct {
            resolved_fields: []const usize, // owned slice
            delays: []const DelayDecl, // owned slice
            instructions: []const Instruction, // owned slice
        },
    },
};

pub const CodeGenResult = struct {
    arena: std.heap.ArenaAllocator,
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
    source: Source,
    parse_result: ParseResult,
    module_results: []CodeGenModuleResult, // filled in as we go
    module_visited: []bool, // ditto
};

// codegen entry point
pub fn codegen(source: Source, parse_result: ParseResult, inner_allocator: *std.mem.Allocator) !CodeGenResult {
    var arena = std.heap.ArenaAllocator.init(inner_allocator);
    errdefer arena.deinit();

    var module_visited = try inner_allocator.alloc(bool, parse_result.modules.len);
    defer inner_allocator.free(module_visited);

    std.mem.set(bool, module_visited, false);

    var module_results = try arena.allocator.alloc(CodeGenModuleResult, parse_result.modules.len);

    var builtin_index: usize = 0;
    for (parse_result.builtin_packages) |pkg| {
        for (pkg.builtins) |builtin| {
            module_results[builtin_index] = .{
                .num_outputs = builtin.num_outputs,
                .num_temps = builtin.num_temps,
                .inner = .builtin,
            };
            module_visited[builtin_index] = true;
            builtin_index += 1;
        }
    }

    var self: CodeGenVisitor = .{
        .arena_allocator = &arena.allocator,
        .inner_allocator = inner_allocator,
        .source = source,
        .parse_result = parse_result,
        .module_results = module_results,
        .module_visited = module_visited,
    };

    for (parse_result.modules) |_, i| {
        try visitModule(&self, i, i);
    }

    return CodeGenResult{
        .arena = arena,
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
        const field_name = self.source.getString(field.type_token.source_range);
        const resolved_module_index = for (self.parse_result.modules) |m, i| {
            if (std.mem.eql(u8, field_name, m.name)) {
                break i;
            }
        } else {
            return fail(self.source, field.type_token.source_range, "no module called `<`", .{});
        };

        // check for dependency loops and then recurse
        if (resolved_module_index == self_module_index) {
            return fail(self.source, field.type_token.source_range, "circular dependency in module fields", .{});
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
        .source = self.source,
        .modules = self.parse_result.modules,
        .module_results = self.module_results,
        .module_index = module_index,
        .resolved_fields = resolved_fields,
        .locals = module_info.locals,
        .instructions = std.ArrayList(Instruction).init(self.arena_allocator),
        .temp_buffers = TempManager.init(self.inner_allocator, true),
        .temp_floats = TempManager.init(self.inner_allocator, false), // don't reuse temp floats slots (they become `const` in zig)
        .local_results = try self.arena_allocator.alloc(?ExpressionResult, module_info.locals.len),
        .delays = std.ArrayList(DelayDecl).init(self.arena_allocator),
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

    // diagnostic print
    printBytecode(&state) catch |err| std.debug.warn("printBytecode failed: {}\n", .{err});

    return CodeGenModuleResult{
        .num_outputs = 1,
        .num_temps = state.temp_buffers.finalCount(),
        .inner = .{
            .custom = .{
                .resolved_fields = resolved_fields,
                .delays = state.delays.toOwnedSlice(),
                .instructions = state.instructions.toOwnedSlice(),
            },
        },
    };
}
