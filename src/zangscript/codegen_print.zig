const std = @import("std");
const CodegenState = @import("codegen.zig").CodegenState;
const ExpressionResult = @import("codegen.zig").ExpressionResult;
const BufferValue = @import("codegen.zig").BufferValue;
const FloatValue = @import("codegen.zig").FloatValue;

fn printExpressionResult(self: *const CodegenState, result: ExpressionResult) void {
    switch (result) {
        .temp_buffer => |i| std.debug.warn("temp{}", .{i}),
        .temp_float => |i| std.debug.warn("temp_float{}", .{i}),
        .temp_bool => |i| std.debug.warn("temp_bool{}", .{i}),
        .literal => |literal| {
            switch (literal) {
                .boolean => |value| std.debug.warn("{}", .{value}),
                .number => |value| std.debug.warn("{d}", .{value}),
            }
        },
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
    std.debug.warn("    num_temp_floats: {}\n", .{self.temp_floats.finalCount()});
    std.debug.warn("    num_temp_bools: {}\n", .{self.temp_bools.finalCount()});

    std.debug.warn("bytecode:\n", .{});
    for (instructions) |instr| {
        std.debug.warn("    ", .{});
        switch (instr) {
            .float_to_buffer => |x| {
                std.debug.warn("temp{} = FLOAT_TO_BUFFER ", .{x.out_temp_buffer_index});
                printFloatValue(self, x.in);
                std.debug.warn("\n", .{});
            },
            .arith_float_float => |x| {
                std.debug.warn("temp_float{} = ARITH_FLOAT_FLOAT({}) ", .{ x.out_temp_float_index, x.operator });
                printFloatValue(self, x.a);
                std.debug.warn(" ", .{});
                printFloatValue(self, x.b);
                std.debug.warn("\n", .{});
            },
            .arith_buffer_float => |x| {
                std.debug.warn("temp{} = ARITH_BUFFER_FLOAT({}) ", .{ x.out_temp_buffer_index, x.operator });
                printBufferValue(self, x.a);
                std.debug.warn(" ", .{});
                printFloatValue(self, x.b);
                std.debug.warn("\n", .{});
            },
            .arith_buffer_buffer => |x| {
                std.debug.warn("temp{} = ARITH_BUFFER_BUFFER({}) ", .{ x.out_temp_buffer_index, x.operator });
                printBufferValue(self, x.a);
                std.debug.warn(" ", .{});
                printBufferValue(self, x.b);
                std.debug.warn("\n", .{});
            },
            .call => |call| {
                const field = self.first_pass_result.module_fields[self_module.first_field + call.field_index];
                const callee_module = self.first_pass_result.modules[field.resolved_module_index];
                const callee_params = self.first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];
                std.debug.warn("temp{} = CALL #{}({}: {})\n", .{
                    call.out_temp_buffer_index,
                    call.field_index,
                    field.name,
                    callee_module.name,
                });
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
            .output => |x| {
                std.debug.warn("output0 = ", .{});
                printBufferValue(self, x.value);
                std.debug.warn("\n", .{});
            },
        }
    }
    std.debug.warn("\n", .{});
}
