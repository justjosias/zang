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

// expression will return how it stored its result.
// if it's a temp, the caller needs to make sure to release it (by calling releaseExpressionResult).
pub const ExpressionResult = union(enum) {
    nothing, // like `void`. this is the type of an assignment
    temp_buffer_weak: usize, // not freed by releaseExpressionResult
    temp_buffer: usize,
    temp_float: usize,
    temp_bool: usize,
    literal_boolean: bool,
    literal_number: f32,
    literal_enum_value: []const u8,
    self_param: usize,
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
        // list of temp buffers passed along for the callee's internal use, dependency injection style
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
        self.slot_claimed.deinit();
    }

    fn reportLeaks(self: *const TempManager) void {
        // if we're cleaning up because an error occurred, don't complain
        // about leaks. i don't care about releasing every temp in an
        // error situation.
        var num_leaked: usize = 0;
        for (self.slot_claimed.items) |in_use| {
            if (in_use) {
                num_leaked += 1;
            }
        }
        if (num_leaked > 0) {
            std.debug.warn("error - {} temp(s) leaked in codegen\n", .{num_leaked});
        }
    }

    fn claim(self: *TempManager) !usize {
        for (self.slot_claimed.items) |*in_use, index| {
            if (!in_use.*) {
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

pub const GenError = error{
    Failed,
    OutOfMemory,
};

fn getResultAsFloat(self: *CodegenModuleState, result: ExpressionResult) ?FloatValue {
    return switch (result) {
        .nothing => unreachable,
        .temp_float => |i| FloatValue{ .temp_float_index = i },
        .self_param => |i| if (self.modules[self.module_index].params[i].param_type == .constant)
            FloatValue{ .self_param = i }
        else
            null,
        .literal_number => |value| FloatValue{ .literal = value },
        .literal_boolean, .literal_enum_value, .temp_buffer_weak, .temp_buffer, .temp_bool => null,
    };
}

fn getResultAsBuffer(self: *CodegenModuleState, result: ExpressionResult) ?BufferValue {
    return switch (result) {
        .nothing => unreachable,
        .temp_buffer_weak => |i| BufferValue{ .temp_buffer_index = i },
        .temp_buffer => |i| BufferValue{ .temp_buffer_index = i },
        .self_param => |i| if (self.modules[self.module_index].params[i].param_type == .buffer)
            BufferValue{ .self_param = i }
        else
            null,
        .temp_float, .temp_bool, .literal_boolean, .literal_number, .literal_enum_value => null,
    };
}

fn releaseExpressionResult(self: *CodegenModuleState, result: ExpressionResult) void {
    switch (result) {
        .temp_buffer => |i| self.temp_buffers.release(i),
        else => {},
    }
}

const ResultInfo = union(enum) {
    // none: create a temp for the destination, except for literals/params - those can be passed directly.
    // no type checking (type is propagated from the inside out).
    none,
    // callee_param: create a temp for the destination, except for literals/params - those can be passed directly.
    // type check against the required destination type.
    callee_param: ParamType,
    // result_loc: a destination is already set up, so don't create a temp.
    // type check against the required destination type.
    result_loc: BufferDest,
};

fn genLiteralBoolean(self: *CodegenModuleState, sr: SourceRange, result_info: ResultInfo, value: bool) !ExpressionResult {
    switch (result_info) {
        .none => return ExpressionResult{ .literal_boolean = value },
        .callee_param => |callee_param_type| {
            switch (callee_param_type) {
                .boolean => return ExpressionResult{ .literal_boolean = value },
                .buffer => return fail(self.source, sr, "expected buffer value, found boolean", .{}),
                .constant_or_buffer => return fail(self.source, sr, "expected float or buffer value, found boolean", .{}),
                .constant => return fail(self.source, sr, "expected float value, found boolean", .{}),
                .one_of => |e| return fail(self.source, sr, "expected one of |, found boolean", .{e.values}),
            }
        },
        .result_loc => return fail(self.source, sr, "expected buffer value, found boolean", .{}),
    }
}

fn genLiteralNumber(self: *CodegenModuleState, sr: SourceRange, result_info: ResultInfo, value: f32) !ExpressionResult {
    switch (result_info) {
        .none => return ExpressionResult{ .literal_number = value },
        .callee_param => |callee_param_type| {
            switch (callee_param_type) {
                .boolean => return fail(self.source, sr, "expected boolean value, found number", .{}),
                .buffer => {
                    const temp_buffer_index = try self.temp_buffers.claim();
                    try self.instructions.append(.{
                        .float_to_buffer = .{
                            .out = .{ .temp_buffer_index = temp_buffer_index },
                            .in = .{ .literal = value },
                        },
                    });
                    return ExpressionResult{ .temp_buffer = temp_buffer_index };
                },
                .constant_or_buffer, .constant => { // codegen_zig will wrap for cob types
                    return ExpressionResult{ .literal_number = value };
                },
                .one_of => |e| return fail(self.source, sr, "expected one of |, found number", .{e.values}),
            }
        },
        .result_loc => |result_loc| {
            try self.instructions.append(.{
                .float_to_buffer = .{
                    .out = result_loc,
                    .in = .{ .literal = value },
                },
            });
            return ExpressionResult.nothing;
        },
    }
}

fn genLiteralEnumValue(self: *CodegenModuleState, sr: SourceRange, result_info: ResultInfo, value: []const u8) !ExpressionResult {
    switch (result_info) {
        .none => return ExpressionResult{ .literal_enum_value = value },
        .callee_param => |callee_param_type| {
            switch (callee_param_type) {
                .one_of => |e| {
                    for (e.values) |allowed_value| {
                        if (std.mem.eql(u8, allowed_value, value)) break;
                    } else return fail(self.source, sr, "expected one of |", .{e.values});
                    return ExpressionResult{ .literal_enum_value = value };
                },
                .boolean => return fail(self.source, sr, "expected boolean value, found enum value", .{}),
                .buffer => return fail(self.source, sr, "expected buffer value, found enum value", .{}),
                .constant_or_buffer => return fail(self.source, sr, "expected float or buffer value, found enum value", .{}),
                .constant => return fail(self.source, sr, "expected float value, found enum value", .{}),
            }
        },
        .result_loc => return fail(self.source, sr, "expected buffer value, found enum value", .{}),
    }
}

fn genLocal(self: *CodegenModuleState, sr: SourceRange, result_info: ResultInfo, local_index: usize) !ExpressionResult {
    const temp_buffer_index = self.local_temps[local_index].?;
    switch (result_info) {
        .none => {
            return ExpressionResult{ .temp_buffer_weak = temp_buffer_index };
        },
        .callee_param => |callee_param_type| {
            switch (callee_param_type) {
                .boolean => return fail(self.source, sr, "expected boolean value, found buffer", .{}),
                .buffer, .constant_or_buffer => { // codegen_zig will wrap for cob types
                    return ExpressionResult{ .temp_buffer_weak = temp_buffer_index };
                },
                .constant => return fail(self.source, sr, "expected float value, found buffer", .{}),
                .one_of => |e| return fail(self.source, sr, "expected one of |, found buffer", .{e.values}),
            }
        },
        .result_loc => |result_loc| {
            try self.instructions.append(.{
                .copy_buffer = .{
                    .out = result_loc,
                    .in = .{ .temp_buffer_index = temp_buffer_index },
                },
            });
            return ExpressionResult.nothing;
        },
    }
}

fn genSelfParam(self: *CodegenModuleState, sr: SourceRange, result_info: ResultInfo, param_index: usize) !ExpressionResult {
    // immediately turn constant_or_buffer into buffer (the rest of codegen isn't able to work with constant_or_buffer)
    if (self.modules[self.module_index].params[param_index].param_type == .constant_or_buffer) {
        const buffer_dest = try requestBufferDest(self, result_info);
        try self.instructions.append(.{ .cob_to_buffer = .{ .out = buffer_dest, .in_self_param = param_index } });
        return try commitBufferDest(self, result_info, sr, buffer_dest);
    } else {
        return ExpressionResult{ .self_param = param_index };
    }
}

// caller wants to return a float-typed result
fn requestFloatDest(self: *CodegenModuleState, result_info: ResultInfo) FloatDest {
    const temp_float_index = self.num_temp_floats;
    self.num_temp_floats += 1;
    return .{ .temp_float_index = temp_float_index };
}
fn commitFloatDest(self: *CodegenModuleState, result_info: ResultInfo, sr: SourceRange, fd: FloatDest) !ExpressionResult {
    switch (result_info) {
        .none => {
            return ExpressionResult{ .temp_float = fd.temp_float_index };
        },
        .callee_param => |callee_param_type| {
            switch (callee_param_type) {
                .boolean => return fail(self.source, sr, "expected boolean value, found float", .{}),
                .buffer => {
                    const temp_buffer_index = try self.temp_buffers.claim();
                    try self.instructions.append(.{
                        .float_to_buffer = .{
                            .out = .{ .temp_buffer_index = temp_buffer_index },
                            .in = .{ .temp_float_index = fd.temp_float_index },
                        },
                    });
                    return ExpressionResult{ .temp_buffer = temp_buffer_index };
                },
                .constant, .constant_or_buffer => { // codegen_zig will wrap for cob types
                    return ExpressionResult{ .temp_float = fd.temp_float_index };
                },
                .one_of => |e| return fail(self.source, sr, "expected one of |, found float", .{e.values}),
            }
        },
        .result_loc => |buffer_dest| {
            try self.instructions.append(.{
                .float_to_buffer = .{
                    .out = buffer_dest,
                    .in = .{ .temp_float_index = fd.temp_float_index },
                },
            });
            return ExpressionResult.nothing;
        },
    }
}

// caller wants to return a buffer-typed result
fn requestBufferDest(self: *CodegenModuleState, result_info: ResultInfo) !BufferDest {
    return switch (result_info) {
        .none, .callee_param => .{ .temp_buffer_index = try self.temp_buffers.claim() },
        .result_loc => |buffer_dest| buffer_dest,
    };
}
fn commitBufferDest(self: *CodegenModuleState, result_info: ResultInfo, sr: SourceRange, buffer_dest: BufferDest) !ExpressionResult {
    switch (result_info) {
        .none => {
            const temp_buffer_index = switch (buffer_dest) {
                .temp_buffer_index => |i| i,
                .output_index => unreachable,
            };
            return ExpressionResult{ .temp_buffer = temp_buffer_index };
        },
        .callee_param => |callee_param_type| {
            const temp_buffer_index = switch (buffer_dest) {
                .temp_buffer_index => |i| i,
                .output_index => unreachable,
            };
            switch (callee_param_type) {
                .boolean => return fail(self.source, sr, "expected boolean value, found buffer", .{}),
                .buffer, .constant_or_buffer => { // codegen_zig will wrap for cob types
                    return ExpressionResult{ .temp_buffer = temp_buffer_index };
                },
                .constant => return fail(self.source, sr, "expected float value, found buffer", .{}),
                .one_of => |e| return fail(self.source, sr, "expected one of |, found buffer", .{e.values}),
            }
        },
        .result_loc => return ExpressionResult.nothing,
    }
}

fn genNegate(self: *CodegenModuleState, sr: SourceRange, result_info: ResultInfo, expr: *const Expression, maybe_feedback_temp_index: ?usize) !ExpressionResult {
    const ra = try genExpression(self, expr, .none, maybe_feedback_temp_index);
    defer releaseExpressionResult(self, ra);

    if (getResultAsFloat(self, ra)) |a| {
        // float -> float
        const float_dest = requestFloatDest(self, result_info);
        try self.instructions.append(.{ .negate_float_to_float = .{ .out = float_dest, .a = a } });
        return commitFloatDest(self, result_info, sr, float_dest);
    }
    if (getResultAsBuffer(self, ra)) |a| {
        // buffer -> buffer
        const buffer_dest = try requestBufferDest(self, result_info);
        try self.instructions.append(.{ .negate_buffer_to_buffer = .{ .out = buffer_dest, .a = a } });
        return commitBufferDest(self, result_info, sr, buffer_dest);
    }
    return fail(self.source, expr.source_range, "arithmetic can only be performed on numeric types", .{});
}

fn genBinArith(self: *CodegenModuleState, sr: SourceRange, result_info: ResultInfo, op: BinArithOp, ea: *const Expression, eb: *const Expression, maybe_feedback_temp_index: ?usize) !ExpressionResult {
    const ra = try genExpression(self, ea, .none, maybe_feedback_temp_index);
    defer releaseExpressionResult(self, ra);
    const rb = try genExpression(self, eb, .none, maybe_feedback_temp_index);
    defer releaseExpressionResult(self, rb);

    if (getResultAsFloat(self, ra)) |a| {
        if (getResultAsFloat(self, rb)) |b| {
            // float * float -> float
            const float_dest = requestFloatDest(self, result_info);
            try self.instructions.append(.{ .arith_float_float = .{ .out = float_dest, .op = op, .a = a, .b = b } });
            return commitFloatDest(self, result_info, sr, float_dest);
        }
        if (getResultAsBuffer(self, rb)) |b| {
            // float * buffer -> buffer
            const buffer_dest = try requestBufferDest(self, result_info);
            try self.instructions.append(.{ .arith_float_buffer = .{ .out = buffer_dest, .op = op, .a = a, .b = b } });
            return commitBufferDest(self, result_info, sr, buffer_dest);
        }
    }
    if (getResultAsBuffer(self, ra)) |a| {
        if (getResultAsFloat(self, rb)) |b| {
            // buffer * float -> buffer
            const buffer_dest = try requestBufferDest(self, result_info);
            try self.instructions.append(.{ .arith_buffer_float = .{ .out = buffer_dest, .op = op, .a = a, .b = b } });
            return commitBufferDest(self, result_info, sr, buffer_dest);
        }
        if (getResultAsBuffer(self, rb)) |b| {
            // buffer * buffer -> buffer
            const buffer_dest = try requestBufferDest(self, result_info);
            try self.instructions.append(.{ .arith_buffer_buffer = .{ .out = buffer_dest, .op = op, .a = a, .b = b } });
            return commitBufferDest(self, result_info, sr, buffer_dest);
        }
    }
    return fail(self.source, sr, "arithmetic can only be performed on numeric types", .{});
}

fn genCall(self: *CodegenModuleState, sr: SourceRange, result_info: ResultInfo, field_index: usize, args: []const CallArg, maybe_feedback_temp_index: ?usize) !ExpressionResult {
    const field_module_index = self.resolved_fields[field_index];

    // the callee is guaranteed to have had its codegen done already, so its num_temps is known
    const callee_num_temps = self.module_results[field_module_index].num_temps;

    const callee_module = self.modules[field_module_index];

    // pass params
    for (args) |a| {
        for (callee_module.params) |param| {
            if (std.mem.eql(u8, a.param_name, param.name)) break;
        } else {
            return fail(self.source, a.param_name_token.source_range, "invalid param `<`", .{});
        }
    }
    var arg_results = try self.arena_allocator.alloc(ExpressionResult, callee_module.params.len);
    for (callee_module.params) |param, i| {
        // find this arg in the call node
        var maybe_arg: ?CallArg = null;
        for (args) |a| {
            if (std.mem.eql(u8, a.param_name, param.name)) {
                if (maybe_arg != null) {
                    return fail(self.source, a.param_name_token.source_range, "param `<` provided more than once", .{});
                }
                maybe_arg = a;
            }
        }
        const arg = maybe_arg orelse return fail(self.source, sr, "call is missing param `#`", .{param.name});
        arg_results[i] = try genExpression(self, arg.value, .{ .callee_param = param.param_type }, maybe_feedback_temp_index);
    }
    defer for (callee_module.params) |param, i| releaseExpressionResult(self, arg_results[i]);

    // the callee needs temps for its own internal use
    var temps = try self.arena_allocator.alloc(usize, callee_num_temps);
    for (temps) |*ptr| {
        ptr.* = try self.temp_buffers.claim();
    }
    defer for (temps) |temp_buffer_index| self.temp_buffers.release(temp_buffer_index);

    const buffer_dest = try requestBufferDest(self, result_info);
    try self.instructions.append(.{
        .call = .{
            .out = buffer_dest,
            .field_index = field_index,
            .temps = temps,
            .args = arg_results,
        },
    });
    return commitBufferDest(self, result_info, sr, buffer_dest);
}

fn genDelayLevelStatement(self: *CodegenModuleState, statement: Statement, out: BufferDest, feedback_out_temp_index: usize, feedback_temp_index: usize) !void {
    switch (statement) {
        .let_assignment => |x| {
            try genLetAssignment(self, x.local_index, x.expression, feedback_temp_index);
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

fn genDelay(self: *CodegenModuleState, sr: SourceRange, result_info: ResultInfo, delay: Delay, maybe_feedback_temp_index: ?usize) !ExpressionResult {
    if (maybe_feedback_temp_index != null) {
        return fail(self.source, sr, "you cannot nest delay operations", .{}); // i might be able to support this, but why?
    }

    const delay_index = self.delays.items.len;
    try self.delays.append(.{ .num_samples = delay.num_samples });

    const feedback_temp_index = try self.temp_buffers.claim();
    defer self.temp_buffers.release(feedback_temp_index);

    const buffer_dest = try requestBufferDest(self, result_info);

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
        try genDelayLevelStatement(self, statement, buffer_dest, feedback_out_temp_index, feedback_temp_index);
    }

    try self.instructions.append(.{
        .delay_end = .{
            .out = buffer_dest,
            .feedback_out_temp_buffer_index = feedback_out_temp_index,
            .delay_index = delay_index,
        },
    });

    return commitBufferDest(self, result_info, sr, buffer_dest);
}

// generate bytecode instructions for an expression
fn genExpression(self: *CodegenModuleState, expression: *const Expression, result_info: ResultInfo, maybe_feedback_temp_index: ?usize) GenError!ExpressionResult {
    const sr = expression.source_range;

    switch (expression.inner) {
        .literal_boolean => |value| return try genLiteralBoolean(self, sr, result_info, value),
        .literal_number => |value| return try genLiteralNumber(self, sr, result_info, value),
        .literal_enum_value => |value| return try genLiteralEnumValue(self, sr, result_info, value),
        .local => |local_index| return try genLocal(self, sr, result_info, local_index),
        .self_param => |param_index| return try genSelfParam(self, sr, result_info, param_index),
        .negate => |expr| return try genNegate(self, sr, result_info, expr, maybe_feedback_temp_index),
        .bin_arith => |m| return try genBinArith(self, sr, result_info, m.op, m.a, m.b, maybe_feedback_temp_index),
        .call => |call| return try genCall(self, sr, result_info, call.field_index, call.args, maybe_feedback_temp_index),
        .delay => |delay| return try genDelay(self, sr, result_info, delay, maybe_feedback_temp_index),
        .feedback => {
            const feedback_temp_index = maybe_feedback_temp_index orelse {
                return fail(self.source, expression.source_range, "`feedback` can only be used within a `delay` operation", .{});
            };
            return ExpressionResult{ .temp_buffer_weak = feedback_temp_index };
        },
    }
}

fn genLetAssignment(self: *CodegenModuleState, local_index: usize, expression: *const Expression, maybe_feedback_temp_index: ?usize) GenError!void {
    // for now, only buffer type is supported for let-assignments
    // create a "temp" to hold the value
    const temp_buffer_index = try self.temp_buffers.claim();

    // mark the temp to be released at the end of all codegen
    self.local_temps[local_index] = temp_buffer_index;

    const result_info: ResultInfo = .{
        .result_loc = .{ .temp_buffer_index = temp_buffer_index },
    };
    const result = try genExpression(self, expression, result_info, maybe_feedback_temp_index);
    defer releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
}

fn genTopLevelStatement(self: *CodegenModuleState, statement: Statement) !void {
    switch (statement) {
        .let_assignment => |x| {
            try genLetAssignment(self, x.local_index, x.expression, null);
        },
        .output => |expression| {
            const result_info: ResultInfo = .{ .result_loc = .{ .output_index = 0 } };
            const result = try genExpression(self, expression, result_info, null);
            defer releaseExpressionResult(self, result); // this should do nothing (because we passed a result loc)
        },
        .feedback => |expression| {
            return fail(self.source, expression.source_range, "`feedback` can only be used within a `delay` operation", .{});
        },
    }
}

pub const CodeGenModuleResult = struct {
    is_builtin: bool,
    num_outputs: usize,
    num_temps: usize,
    // if is_builtin is true, the following are undefined
    resolved_fields: []const usize, // owned slice
    delays: []const DelayDecl, // owned slice
    instructions: []const Instruction, // owned slice
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
                .is_builtin = true,
                .instructions = undefined, // FIXME - should be null
                .num_outputs = builtin.num_outputs,
                .num_temps = builtin.num_temps,
                .resolved_fields = undefined, // FIXME - should be null?
                .delays = undefined, // FIXME - should be null?
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
        .temp_buffers = TempManager.init(self.inner_allocator), // frees its own memory in deinit
        .num_temp_floats = 0,
        .num_temp_bools = 0,
        .local_temps = try self.arena_allocator.alloc(?usize, module_info.locals.len),
        .delays = std.ArrayList(DelayDecl).init(self.arena_allocator),
    };
    defer state.temp_buffers.deinit();

    std.mem.set(?usize, state.local_temps, null);

    for (module_info.scope.statements.items) |statement| {
        try genTopLevelStatement(&state, statement);
    }

    for (state.local_temps) |maybe_temp_buffer_index| {
        const temp_buffer_index = maybe_temp_buffer_index orelse continue;
        state.temp_buffers.release(temp_buffer_index);
    }

    state.temp_buffers.reportLeaks();

    // diagnostic print
    printBytecode(&state) catch |err| std.debug.warn("printBytecode failed: {}\n", .{err});

    return CodeGenModuleResult{
        .is_builtin = false,
        .num_outputs = 1,
        .num_temps = state.temp_buffers.finalCount(),
        .resolved_fields = resolved_fields,
        .delays = state.delays.toOwnedSlice(),
        .instructions = state.instructions.toOwnedSlice(),
    };
}
