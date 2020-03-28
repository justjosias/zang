const std = @import("std");
const CodegenState = @import("codegen.zig").CodegenState;

pub fn printBytecode(self: *CodegenState) void {
    const self_module = self.first_pass_result.modules[self.module_index];
    const instructions = self.instructions.span();

    std.debug.warn("num_temps: {}\n", .{self.num_temps});
    std.debug.warn("num_temp_floats: {}\n", .{self.num_temp_floats});
    std.debug.warn("num_temp_bools: {}\n", .{self.num_temp_bools});
    std.debug.warn("bytecode:\n", .{});
    for (instructions) |instr| {
        std.debug.warn("    ", .{});
        switch (instr) {
            .call => |call| {
                switch (call.result_loc) {
                    .buffer => |buffer_loc| {
                        switch (buffer_loc) {
                            .output => |n| std.debug.warn("output{}", .{n}),
                            .temp => |n| std.debug.warn("temp{}", .{n}),
                        }
                    },
                    .temp_float => |n| std.debug.warn("temp_float{}", .{n}),
                    .temp_bool => |n| std.debug.warn("temp_bool{}", .{n}),
                }
                const field = self.first_pass_result.module_fields[self_module.first_field + call.field_index];
                const callee_module_name = self.first_pass_result.modules[field.resolved_module_index].name;
                const callee_params = blk: {
                    const callee_module = self.first_pass_result.modules[field.resolved_module_index];
                    break :blk self.first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];
                };
                std.debug.warn(" = CALL #{}({}: {})\n", .{ call.field_index, field.name, callee_module_name });
                std.debug.warn("        temps: [", .{});
                for (call.temps.span()) |temp, i| {
                    if (i > 0) std.debug.warn(", ", .{});
                    std.debug.warn("temp{}", .{temp});
                }
                std.debug.warn("]\n", .{});
                for (call.args) |arg, i| {
                    std.debug.warn("        {} = ", .{callee_params[i].name});
                    switch (arg) {
                        .temp => |v| {
                            std.debug.warn("temp{}\n", .{v});
                        },
                        .temp_float => |n| {
                            std.debug.warn("temp_float{}\n", .{n});
                        },
                        .temp_bool => |n| {
                            std.debug.warn("temp_bool{}\n", .{n});
                        },
                    }
                }
            },
            .load_constant => |x| {
                std.debug.warn("temp_float{} = LOADCONSTANT {d}\n", .{ x.out_index, x.value });
            },
            .load_boolean => |x| {
                std.debug.warn("temp_bool{} = LOADBOOLEAN {}\n", .{ x.out_index, x.value });
            },
            .float_to_buffer => |x| {
                switch (x.out) {
                    .temp => |n| std.debug.warn("temp{}", .{n}),
                    .output => |n| std.debug.warn("output{}", .{n}),
                }
                std.debug.warn(" = FLOAT_TO_BUFFER temp_float{}\n", .{x.in_temp_float});
            },
            .load_param_float => |x| {
                std.debug.warn("temp_float{} = LOADPARAM_FLOAT ${}({})\n", .{
                    x.out_temp_float,
                    x.param_index,
                    self.first_pass_result.module_params[self_module.first_param + x.param_index].name,
                });
            },
            .arith_float_float => |x| {
                std.debug.warn("temp_float{} = ARITH_FLOAT_FLOAT {} temp_float{} temp_float{}\n", .{
                    x.operator,
                    x.out_temp_float,
                    x.a_temp_float,
                    x.b_temp_float,
                });
            },
            .arith_buffer_float => |x| {
                switch (x.out) {
                    .temp => |n| std.debug.warn("temp{}", .{n}),
                    .output => |n| std.debug.warn("output{}", .{n}),
                }
                std.debug.warn(" = ARITH_BUFFER_FLOAT {} temp{} temp_float{}\n", .{
                    x.operator,
                    x.temp_index,
                    x.temp_float_index,
                });
            },
        }
    }
    std.debug.warn("\n", .{});
}
