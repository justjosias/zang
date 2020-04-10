const std = @import("std");
const CodegenState = @import("codegen.zig").CodegenState;
const ExpressionResult = @import("codegen.zig").ExpressionResult;
const BufferValue = @import("codegen.zig").BufferValue;
const FloatValue = @import("codegen.zig").FloatValue;
const BufferDest = @import("codegen.zig").BufferDest;

fn printExpressionResult(self: *const CodegenState, result: ExpressionResult) void {
    switch (result) {
        .nothing => unreachable,
        .temp_buffer_weak => |i| std.debug.warn("temp{}", .{i}),
        .temp_buffer => |i| std.debug.warn("temp{}", .{i}),
        .temp_float => |i| std.debug.warn("temp_float{}", .{i}),
        .temp_bool => |i| std.debug.warn("temp_bool{}", .{i}),
        .literal_boolean => |value| std.debug.warn("{}", .{value}),
        .literal_number => |value| std.debug.warn("{d}", .{value}),
        .literal_enum_value => |str| std.debug.warn("'{}'", .{str}),
        .self_param => |i| {
            const module = self.first_pass_result.modules[self.module_index];
            const param = self.first_pass_result.module_params[module.first_param + i];
            std.debug.warn("params.{}", .{param.name});
        },
    }
}

fn printFloatValue(self: *const CodegenState, value: FloatValue) void {
    switch (value) {
        .temp_float_index => |i| std.debug.warn("temp_float{}", .{i}),
        .self_param => |i| { // guaranteed to be of type `constant`
            const module = self.first_pass_result.modules[self.module_index];
            const param = self.first_pass_result.module_params[module.first_param + i];
            std.debug.warn("params.{}", .{param.name});
        },
        .literal => |v| std.debug.warn("{d}", .{v}),
    }
}

fn printBufferDest(self: *const CodegenState, dest: BufferDest) void {
    switch (dest) {
        .temp_buffer_index => |i| std.debug.warn("temp{}", .{i}),
        .output_index => |i| std.debug.warn("output{}", .{i}),
    }
}

fn printBufferValue(self: *const CodegenState, value: BufferValue) void {
    switch (value) {
        .temp_buffer_index => |i| std.debug.warn("temp{}", .{i}),
        .self_param => |i| { // guaranteed to be of type `buffer`
            const module = self.first_pass_result.modules[self.module_index];
            const param = self.first_pass_result.module_params[module.first_param + i];
            std.debug.warn("params.{}", .{param.name});
        },
    }
}

pub fn printBytecode(self: *CodegenState) void {
    const self_module = self.first_pass_result.modules[self.module_index];
    const instructions = self.instructions.span();

    std.debug.warn("module '{}'\n", .{self_module.name});

    std.debug.warn("    num_temps: {}\n", .{self.temp_buffers.finalCount()});
    std.debug.warn("    num_temp_floats: {}\n", .{self.num_temp_floats});
    std.debug.warn("    num_temp_bools: {}\n", .{self.num_temp_bools});

    std.debug.warn("bytecode:\n", .{});
    for (instructions) |instr| {
        std.debug.warn("    ", .{});
        switch (instr) {
            .copy_buffer => |x| {
                printBufferDest(self, x.out);
                std.debug.warn(" = ", .{});
                printBufferValue(self, x.in);
                std.debug.warn("\n", .{});
            },
            .float_to_buffer => |x| {
                printBufferDest(self, x.out);
                std.debug.warn(" = FLOAT_TO_BUFFER ", .{});
                printFloatValue(self, x.in);
                std.debug.warn("\n", .{});
            },
            .cob_to_buffer => |x| {
                const module = self.first_pass_result.modules[self.module_index];
                const param = self.first_pass_result.module_params[module.first_param + x.in_self_param];
                printBufferDest(self, x.out);
                std.debug.warn(" = COB_TO_BUFFER params.{}\n", .{param.name});
            },
            .arith_float_float => |x| {
                std.debug.warn("temp_float{} = ARITH_FLOAT_FLOAT({}) ", .{ x.out_temp_float_index, x.operator });
                printFloatValue(self, x.a);
                std.debug.warn(" ", .{});
                printFloatValue(self, x.b);
                std.debug.warn("\n", .{});
            },
            .arith_buffer_float => |x| {
                printBufferDest(self, x.out);
                std.debug.warn(" = ARITH_BUFFER_FLOAT({}) ", .{x.operator});
                printBufferValue(self, x.a);
                std.debug.warn(" ", .{});
                printFloatValue(self, x.b);
                std.debug.warn("\n", .{});
            },
            .arith_buffer_buffer => |x| {
                printBufferDest(self, x.out);
                std.debug.warn(" = ARITH_BUFFER_BUFFER({}) ", .{x.operator});
                printBufferValue(self, x.a);
                std.debug.warn(" ", .{});
                printBufferValue(self, x.b);
                std.debug.warn("\n", .{});
            },
            .call => |call| {
                const field = self.fields[call.field_index];
                const callee_module = self.first_pass_result.modules[field.resolved_module_index];
                const callee_params = self.first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];
                printBufferDest(self, call.out);
                std.debug.warn(" = CALL #{}({})\n", .{ call.field_index, callee_module.name });
                std.debug.warn("        temps: [", .{});
                for (call.temps) |temp, i| {
                    if (i > 0) std.debug.warn(", ", .{});
                    std.debug.warn("temp{}", .{temp});
                }
                std.debug.warn("]\n", .{});
                for (call.args) |arg, i| {
                    std.debug.warn("        {} = ", .{callee_params[i].name});
                    printExpressionResult(self, arg);
                    std.debug.warn("\n", .{});
                }
            },
            .delay_begin => |delay_begin| {
                std.debug.warn("DELAY_BEGIN (feedback provided at temps[{}])\n", .{delay_begin.feedback_temp_buffer_index});
            },
            .delay_end => |delay_end| {
                printBufferDest(self, delay_end.out);
                std.debug.warn(" = DELAY_END ", .{});
                //printBufferValue(self, delay_end.inner_value); // FIXME
                std.debug.warn("\n", .{});
            },
        }
    }
    std.debug.warn("\n", .{});
}
