const std = @import("std");
const PrintHelper = @import("print_helper.zig").PrintHelper;
const CodegenState = @import("codegen.zig").CodegenState;
const CodegenModuleState = @import("codegen.zig").CodegenModuleState;
const ExpressionResult = @import("codegen.zig").ExpressionResult;
const BufferDest = @import("codegen.zig").BufferDest;
const FloatDest = @import("codegen.zig").FloatDest;
const Instruction = @import("codegen.zig").Instruction;

const State = struct {
    cs: *const CodegenState,
    cms: *const CodegenModuleState,
    helper: PrintHelper,

    pub fn print(self: *State, comptime fmt: []const u8, args: var) !void {
        try self.helper.print(self, fmt, args);
    }

    pub fn printArgValue(self: *State, comptime arg_format: []const u8, arg: var) !void {
        if (comptime std.mem.eql(u8, arg_format, "buffer_dest")) {
            try self.printBufferDest(arg);
        } else if (comptime std.mem.eql(u8, arg_format, "float_dest")) {
            try self.printFloatDest(arg);
        } else if (comptime std.mem.eql(u8, arg_format, "expression_result")) {
            try self.printExpressionResult(arg);
        } else {
            @compileError("unknown arg_format: \"" ++ arg_format ++ "\"");
        }
    }

    fn printExpressionResult(self: *State, result: ExpressionResult) std.os.WriteError!void {
        switch (result) {
            .nothing => unreachable,
            .temp_buffer => |temp_ref| try self.print("temp{usize}", .{temp_ref.index}),
            .temp_float => |temp_ref| try self.print("temp_float{usize}", .{temp_ref.index}),
            .literal_boolean => |value| try self.print("{bool}", .{value}),
            .literal_number => |value| try self.print("{number_literal}", .{value}),
            .literal_enum_value => |v| {
                try self.print("'{str}'", .{v.label});
                if (v.payload) |payload| {
                    try self.print("({expression_result})", .{payload.*});
                }
            },
            .curve_ref => |i| try self.print("${str}", .{self.cs.curves[i].name}),
            .self_param => |i| {
                const module = self.cs.modules[self.cms.module_index];
                try self.print("params.{str}", .{module.params[i].name});
            },
            .track_param => |x| {
                try self.print("@{str}", .{self.cs.tracks[x.track_index].params[x.param_index].name});
            },
        }
    }

    fn printFloatDest(self: *State, dest: FloatDest) !void {
        try self.print("temp_float{usize}", .{dest.temp_float_index});
    }

    fn printBufferDest(self: *State, dest: BufferDest) !void {
        switch (dest) {
            .temp_buffer_index => |i| try self.print("temp{usize}", .{i}),
            .output_index => |i| try self.print("output{usize}", .{i}),
        }
    }

    fn indent(self: *State, indentation: usize) !void {
        var i: usize = 0;
        while (i < indentation) : (i += 1) {
            try self.print("    ", .{});
        }
    }
};

pub fn printBytecode(out: std.io.StreamSource.OutStream, cs: *const CodegenState, cms: *const CodegenModuleState) !void {
    var self: State = .{
        .cs = cs,
        .cms = cms,
        .helper = PrintHelper.init(out),
    };

    const self_module = cs.modules[cms.module_index];

    try self.print("module '{str}'\n", .{self_module.name});
    try self.print("    num_temp_buffers: {usize}\n", .{cms.temp_buffers.finalCount()});
    try self.print("    num_temp_floats: {usize}\n", .{cms.temp_floats.finalCount()});
    try self.print("bytecode:\n", .{});
    for (cms.instructions.items) |instr| {
        try printInstruction(&self, instr, 1);
    }
    try self.print("\n", .{});

    self.helper.finish();
}

fn printInstruction(self: *State, instr: Instruction, indentation: usize) std.os.WriteError!void {
    try self.indent(indentation);
    switch (instr) {
        .copy_buffer => |x| {
            try self.print("{buffer_dest} = {expression_result}\n", .{ x.out, x.in });
        },
        .float_to_buffer => |x| {
            try self.print("{buffer_dest} = {expression_result}\n", .{ x.out, x.in });
        },
        .cob_to_buffer => |x| {
            const module = self.cs.modules[self.cms.module_index];
            try self.print("{buffer_dest} = COB_TO_BUFFER params.{str}\n", .{ x.out, module.params[x.in_self_param].name });
        },
        .arith_float => |x| {
            try self.print("{float_dest} = ARITH_FLOAT({auto}) {expression_result}\n", .{ x.out, x.op, x.a });
        },
        .arith_buffer => |x| {
            try self.print("{buffer_dest} = ARITH_BUFFER({auto}) {expression_result}\n", .{ x.out, x.op, x.a });
        },
        .arith_float_float => |x| {
            try self.print("{float_dest} = ARITH_FLOAT_FLOAT({auto}) {expression_result} {expression_result}\n", .{ x.out, x.op, x.a, x.b });
        },
        .arith_float_buffer => |x| {
            try self.print("{buffer_dest} = ARITH_FLOAT_BUFFER({auto}) {expression_result} {expression_result}\n", .{ x.out, x.op, x.a, x.b });
        },
        .arith_buffer_float => |x| {
            try self.print("{buffer_dest} = ARITH_BUFFER_FLOAT({auto}) {expression_result} {expression_result}\n", .{ x.out, x.op, x.a, x.b });
        },
        .arith_buffer_buffer => |x| {
            try self.print("{buffer_dest} = ARITH_BUFFER_BUFFER({auto}) {expression_result} {expression_result}\n", .{ x.out, x.op, x.a, x.b });
        },
        .call => |call| {
            const field_module_index = self.cms.resolved_fields[call.field_index];
            const callee_module = self.cs.modules[field_module_index];
            try self.print("{buffer_dest} = CALL #{usize}({str})\n", .{ call.out, call.field_index, callee_module.name });
            try self.indent(indentation + 1);
            try self.print("temps: [", .{});
            for (call.temps) |temp, i| {
                if (i > 0) try self.print(", ", .{});
                try self.print("temp{usize}", .{temp});
            }
            try self.print("]\n", .{});
            for (call.args) |arg, i| {
                try self.indent(indentation + 1);
                try self.print("{str} = {expression_result}\n", .{ callee_module.params[i].name, arg });
            }
        },
        .track_call => |track_call| {
            try self.print("{buffer_dest} = TRACK_CALL @{str}:\n", .{ track_call.out, self.cs.tracks[track_call.track_index].name });
            for (track_call.instructions) |sub_instr| {
                try printInstruction(self, sub_instr, indentation + 1);
            }
        },
        .delay => |delay| {
            try self.print("{buffer_dest} = DELAY (feedback provided at temps[{usize}]):\n", .{ delay.out, delay.feedback_temp_buffer_index });
            for (delay.instructions) |sub_instr| {
                try printInstruction(self, sub_instr, indentation + 1);
            }
            //try self.print("{buffer_dest} = DELAY_END {expression_result}\n", .{delay_end.out,delay_end.inner_value}); // FIXME
        },
    }
}
