const std = @import("std");
const CodegenState = @import("codegen.zig").CodegenState;
const ExpressionResult = @import("codegen.zig").ExpressionResult;
const BufferValue = @import("codegen.zig").BufferValue;
const FloatValue = @import("codegen.zig").FloatValue;
const BufferDest = @import("codegen.zig").BufferDest;

const State = struct {
    codegen_state: *const CodegenState,
    out: *std.fs.File.OutStream,

    fn print(self: *State, comptime fmt: []const u8, args: var) !void {
        comptime var arg_index: usize = 0;
        comptime var i: usize = 0;
        inline while (i < fmt.len) {
            if (fmt[i] == '}' and i + 1 < fmt.len and fmt[i + 1] == '}') {
                try self.out.writeByte('}');
                i += 2;
                continue;
            }
            if (fmt[i] == '{') {
                i += 1;

                if (i < fmt.len and fmt[i] == '{') {
                    try self.out.writeByte('{');
                    i += 1;
                    continue;
                }

                // find the closing brace
                const start = i;
                inline while (i < fmt.len) : (i += 1) {
                    if (fmt[i] == '}') break;
                }
                if (i == fmt.len) {
                    @compileError("`{` must be followed by `}`");
                }
                const arg_format = fmt[start..i];
                i += 1;

                const arg = args[arg_index];
                arg_index += 1;

                if (comptime std.mem.eql(u8, arg_format, "auto")) {
                    try self.out.print("{}", .{arg});
                } else if (comptime std.mem.eql(u8, arg_format, "bool")) {
                    try self.out.print("{}", .{@as(bool, arg)});
                } else if (comptime std.mem.eql(u8, arg_format, "f32")) {
                    try self.out.print("{d}", .{@as(f32, arg)});
                } else if (comptime std.mem.eql(u8, arg_format, "usize")) {
                    try self.out.print("{}", .{@as(usize, arg)});
                } else if (comptime std.mem.eql(u8, arg_format, "str")) {
                    try self.out.writeAll(arg);
                } else if (comptime std.mem.eql(u8, arg_format, "buffer_value")) {
                    try self.printBufferValue(arg);
                } else if (comptime std.mem.eql(u8, arg_format, "buffer_dest")) {
                    try self.printBufferDest(arg);
                } else if (comptime std.mem.eql(u8, arg_format, "float_value")) {
                    try self.printFloatValue(arg);
                } else if (comptime std.mem.eql(u8, arg_format, "expression_result")) {
                    try self.printExpressionResult(arg);
                } else {
                    @compileError("unknown arg_format: \"" ++ arg_format ++ "\"");
                }
            } else {
                try self.out.writeByte(fmt[i]);
                i += 1;
            }
        }
    }

    fn printExpressionResult(self: *State, result: ExpressionResult) !void {
        switch (result) {
            .nothing => unreachable,
            .temp_buffer_weak => |i| try self.print("temp{usize}", .{i}),
            .temp_buffer => |i| try self.print("temp{usize}", .{i}),
            .temp_float => |i| try self.print("temp_float{usize}", .{i}),
            .temp_bool => |i| try self.print("temp_bool{usize}", .{i}),
            .literal_boolean => |value| try self.print("{bool}", .{value}),
            .literal_number => |value| try self.print("{f32}", .{value}),
            .literal_enum_value => |str| try self.print("'{str}'", .{str}),
            .self_param => |i| {
                const module = self.codegen_state.first_pass_result.modules[self.codegen_state.module_index];
                try self.print("params.{str}", .{module.params[i].name});
            },
        }
    }

    fn printFloatValue(self: *State, value: FloatValue) !void {
        switch (value) {
            .temp_float_index => |i| try self.print("temp_float{usize}", .{i}),
            .self_param => |i| { // guaranteed to be of type `constant`
                const module = self.codegen_state.first_pass_result.modules[self.codegen_state.module_index];
                try self.print("params.{str}", .{module.params[i].name});
            },
            .literal => |v| try self.print("{f32}", .{v}),
        }
    }

    fn printBufferDest(self: *State, dest: BufferDest) !void {
        switch (dest) {
            .temp_buffer_index => |i| try self.print("temp{usize}", .{i}),
            .output_index => |i| try self.print("output{usize}", .{i}),
        }
    }

    fn printBufferValue(self: *State, value: BufferValue) !void {
        switch (value) {
            .temp_buffer_index => |i| try self.print("temp{usize}", .{i}),
            .self_param => |i| { // guaranteed to be of type `buffer`
                const module = self.codegen_state.first_pass_result.modules[self.codegen_state.module_index];
                try self.print("params.{str}", .{module.params[i].name});
            },
        }
    }
};

pub fn printBytecode(codegen_state: *const CodegenState) !void {
    const stderr_file = std.io.getStdErr();
    var stderr_file_out_stream = stderr_file.outStream();

    var self: State = .{
        .codegen_state = codegen_state,
        .out = &stderr_file_out_stream,
    };

    const self_module = codegen_state.first_pass_result.modules[codegen_state.module_index];

    try self.print("module '{str}'\n", .{self_module.name});
    try self.print("    num_temps: {usize}\n", .{codegen_state.temp_buffers.finalCount()});
    try self.print("    num_temp_floats: {usize}\n", .{codegen_state.num_temp_floats});
    try self.print("    num_temp_bools: {usize}\n", .{codegen_state.num_temp_bools});
    try self.print("bytecode:\n", .{});
    for (codegen_state.instructions.items) |instr| {
        try self.print("    ", .{});
        switch (instr) {
            .copy_buffer => |x| {
                try self.print("{buffer_dest} = {buffer_value}\n", .{ x.out, x.in });
            },
            .float_to_buffer => |x| {
                try self.print("{buffer_dest} = {float_value}\n", .{ x.out, x.in });
            },
            .cob_to_buffer => |x| {
                const module = self.codegen_state.first_pass_result.modules[self.codegen_state.module_index];
                try self.print("{buffer_dest} = COB_TO_BUFFER params.{str}\n", .{ x.out, module.params[x.in_self_param].name });
            },
            .negate_float_to_float => |x| {
                try self.print("temp_float{usize} = NEGATE_FLOAT_TO_FLOAT {float_value}\n", .{ x.out_temp_float_index, x.a });
            },
            .negate_buffer_to_buffer => |x| {
                try self.print("{buffer_dest} = NEGATE_BUFFER_TO_BUFFER {buffer_value}\n", .{ x.out, x.a });
            },
            .arith_float_float => |x| {
                try self.print("temp_float{usize} = ARITH_FLOAT_FLOAT({auto}) {float_value} {float_value}\n", .{ x.out_temp_float_index, x.operator, x.a, x.b });
            },
            .arith_float_buffer => |x| {
                try self.print("{buffer_dest} = ARITH_FLOAT_BUFFER({auto}) {float_value} {buffer_value}\n", .{ x.out, x.operator, x.a, x.b });
            },
            .arith_buffer_float => |x| {
                try self.print("{buffer_dest} = ARITH_BUFFER_FLOAT({auto}) {buffer_value} {float_value}\n", .{ x.out, x.operator, x.a, x.b });
            },
            .arith_buffer_buffer => |x| {
                try self.print("{buffer_dest} = ARITH_BUFFER_BUFFER({auto}) {buffer_value} {buffer_value}\n", .{ x.out, x.operator, x.a, x.b });
            },
            .call => |call| {
                const field = codegen_state.fields[call.field_index];
                const callee_module = codegen_state.first_pass_result.modules[field.resolved_module_index];
                try self.print("{buffer_dest} = CALL #{usize}({str})\n", .{ call.out, call.field_index, callee_module.name });
                try self.print("        temps: [", .{});
                for (call.temps) |temp, i| {
                    if (i > 0) try self.print(", ", .{});
                    try self.print("temp{usize}", .{temp});
                }
                try self.print("]\n", .{});
                for (call.args) |arg, i| {
                    try self.print("        {str} = {expression_result}\n", .{ callee_module.params[i].name, arg });
                }
            },
            .delay_begin => |delay_begin| {
                try self.print("DELAY_BEGIN (feedback provided at temps[{usize}])\n", .{delay_begin.feedback_temp_buffer_index});
            },
            .delay_end => |delay_end| {
                //try self.print("{buffer_dest} = DELAY_END {buffer_value}\n", .{delay_end.out,delay_end.inner_value}); // FIXME
                try self.print("{buffer_dest} = DELAY_END\n", .{delay_end.out});
            },
        }
    }
    try self.print("\n", .{});
}
