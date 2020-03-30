const std = @import("std");
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const Module = @import("first_pass.zig").Module;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const ExpressionResult = @import("codegen.zig").ExpressionResult;
const BufferValue = @import("codegen.zig").BufferValue;
const FloatValue = @import("codegen.zig").FloatValue;
const builtins = @import("builtins.zig").builtins;

fn printExpressionResult(first_pass_result: FirstPassResult, module: Module, out: var, result: ExpressionResult) !void {
    switch (result) {
        .temp_buffer => |i| try out.print("temps[{}]", .{i}),
        .temp_float => |i| try out.print("temp_float{}", .{i}),
        .temp_bool => |i| try out.print("temp_bool{}", .{i}),
        .literal => |literal| {
            switch (literal) {
                .boolean => |value| try out.print("{}", .{value}),
                .number => |value| try out.print("{d}", .{value}),
                .enum_value => |str| try out.print(".{}", .{str}),
            }
        },
        .self_param => |i| try out.print("params.{}", .{first_pass_result.module_params[module.first_param + i].name}),
    }
}

fn printBufferValue(first_pass_result: FirstPassResult, module: Module, out: var, value: BufferValue) !void {
    switch (value) {
        .temp_buffer_index => |i| try out.print("temps[{}]", .{i}),
        .self_param => |i| try out.print("params.{}", .{first_pass_result.module_params[module.first_param + i].name}),
    }
}

fn printFloatValue(first_pass_result: FirstPassResult, module: Module, out: var, value: FloatValue) !void {
    switch (value) {
        .temp_float_index => |i| try out.print("temp_float{}", .{i}),
        .self_param => |i| try out.print("params.{}", .{first_pass_result.module_params[module.first_param + i].name}),
        .literal => |v| try out.print("{d}", .{v}),
    }
}

pub fn generateZig(first_pass_result: FirstPassResult, code_gen_results: []const CodeGenResult) !void {
    const stdout_file = std.io.getStdOut();
    var stdout_file_out_stream = stdout_file.outStream();
    const out = &stdout_file_out_stream.stream;

    try out.print("const zang = @import(\"zang\");\n", .{});
    for (first_pass_result.modules) |module, i| {
        if (i < builtins.len) {
            continue;
        }

        const code_gen_result = code_gen_results[i];
        try out.print("\n", .{});
        try out.print("pub const {} = struct {{\n", .{module.name});
        try out.print("    pub const num_outputs = {};\n", .{code_gen_result.num_outputs});
        try out.print("    pub const num_temps = {};\n", .{code_gen_result.num_temps});
        try out.print("    pub const Params = struct {{\n", .{});
        for (first_pass_result.module_params[module.first_param .. module.first_param + module.num_params]) |param| {
            const type_name = switch (param.param_type) {
                .boolean => "bool",
                .buffer => "[]const f32",
                .constant => "f32",
                .constant_or_buffer => "zang.ConstantOrBuffer",
                .one_of => |e| e.zig_name,
            };
            try out.print("        {}: {},\n", .{ param.name, type_name });
        }
        try out.print("    }};\n", .{});
        try out.print("\n", .{});
        for (first_pass_result.module_fields[module.first_field .. module.first_field + module.num_fields]) |field| {
            const module_name = first_pass_result.modules[field.resolved_module_index].zig_name;
            try out.print("    {}: {},\n", .{ field.name, module_name });
        }
        try out.print("\n", .{});
        try out.print("    pub fn init() {} {{\n", .{module.name});
        try out.print("        return .{{\n", .{});
        for (first_pass_result.module_fields[module.first_field .. module.first_field + module.num_fields]) |field| {
            const module_name = first_pass_result.modules[field.resolved_module_index].zig_name;
            try out.print("            .{} = {}.init(),\n", .{ field.name, module_name });
        }
        try out.print("        }};\n", .{});
        try out.print("    }}\n", .{});
        try out.print("\n", .{});
        try out.print("    pub fn paint(self: *{}, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, params: Params) void {{\n", .{module.name});
        for (code_gen_result.instructions) |instr| {
            switch (instr) {
                .float_to_buffer => |x| {
                    try out.print("        zang.set(span, temps[{}], ", .{x.out_temp_buffer_index});
                    try printFloatValue(first_pass_result, module, out, x.in);
                    try out.print(");\n", .{});
                },
                .arith_float_float => |x| {
                    try out.print("        const temp_float{}: f32 = ", .{x.out_temp_float_index});
                    try printFloatValue(first_pass_result, module, out, x.a);
                    try out.print(" {} ", .{
                        switch (x.operator) {
                            .add => "+",
                            .mul => "*",
                        },
                    });
                    try printFloatValue(first_pass_result, module, out, x.b);
                    try out.print(";\n", .{});
                },
                .arith_buffer_float => |x| {
                    try out.print("        zang.zero(span, temps[{}]);\n", .{x.out_temp_buffer_index});
                    try out.print("        zang.{}Scalar(span, temps[{}], ", .{
                        switch (x.operator) {
                            .add => @as([]const u8, "add"),
                            .mul => @as([]const u8, "multiply"),
                        },
                        x.out_temp_buffer_index,
                    });
                    try printBufferValue(first_pass_result, module, out, x.a);
                    try out.print(", ", .{});
                    try printFloatValue(first_pass_result, module, out, x.b);
                    try out.print(");\n", .{});
                },
                .arith_buffer_buffer => |x| {
                    try out.print("        zang.zero(span, temps[{}]);\n", .{x.out_temp_buffer_index});
                    try out.print("        zang.{}(span, temps[{}], ", .{
                        switch (x.operator) {
                            .add => @as([]const u8, "add"),
                            .mul => @as([]const u8, "multiply"),
                        },
                        x.out_temp_buffer_index,
                    });
                    try printBufferValue(first_pass_result, module, out, x.a);
                    try out.print(", ", .{});
                    try printBufferValue(first_pass_result, module, out, x.b);
                    try out.print(");\n", .{});
                },
                .call => |call| {
                    const field = first_pass_result.module_fields[module.first_field + call.field_index];
                    try out.print("        zang.zero(span, temps[{}]);\n", .{call.out_temp_buffer_index});
                    try out.print("        self.{}.paint(span, .{{temps[{}]}}, .{{", .{ field.name, call.out_temp_buffer_index });
                    // callee temps
                    for (call.temps) |n, j| {
                        if (j > 0) {
                            try out.print(", ", .{});
                        }
                        try out.print("temps[{}]", .{n});
                    }
                    // callee params
                    try out.print("}}, .{{\n", .{});
                    const callee_module = first_pass_result.modules[field.resolved_module_index];
                    const callee_params = first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];
                    for (call.args) |arg, j| {
                        const callee_param = callee_params[j];
                        try out.print("            .{} = ", .{callee_param.name});
                        if (callee_param.param_type == .constant_or_buffer) {
                            // coerce to ConstantOrBuffer?
                            switch (arg) {
                                .temp_buffer => |index| try out.print("zang.buffer(temps[{}])", .{index}),
                                .temp_float => |index| try out.print("zang.constant(temp_float{})", .{index}),
                                .temp_bool => unreachable,
                                .literal => |literal| {
                                    switch (literal) {
                                        .boolean => unreachable,
                                        .number => |value| try out.print("zang.constant({d})", .{value}),
                                        .enum_value => unreachable,
                                    }
                                },
                                .self_param => |index| {
                                    const param = first_pass_result.module_params[module.first_param + index];
                                    switch (param.param_type) {
                                        .boolean => unreachable,
                                        .buffer => try out.print("zang.buffer(params.{})", .{param.name}),
                                        .constant => try out.print("zang.constant(params.{})", .{param.name}),
                                        .constant_or_buffer => try out.print("params.{}", .{param.name}),
                                        .one_of => unreachable,
                                    }
                                },
                            }
                        } else {
                            try printExpressionResult(first_pass_result, module, out, arg);
                        }
                        try out.print(",\n", .{});
                    }
                    try out.print("        }});\n", .{});
                },
                .output => |x| {
                    try out.print("        zang.addInto(span, outputs[0], ", .{});
                    try printBufferValue(first_pass_result, module, out, x.value);
                    try out.print(");\n", .{});
                },
            }
        }
        try out.print("    }}\n", .{});
        try out.print("}};\n", .{});
    }
}
