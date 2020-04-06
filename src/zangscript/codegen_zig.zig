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
        .temp_buffer_weak => |i| try out.print("temps[{}]", .{i}),
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

fn indent(out: var, indentation: usize) !void {
    var i: usize = 0;
    while (i < indentation) : (i += 1) {
        try out.print("    ", .{});
    }
}

pub fn generateZig(first_pass_result: FirstPassResult, code_gen_results: []const CodeGenResult) !void {
    const stdout_file = std.io.getStdOut();
    var stdout_file_out_stream = stdout_file.outStream();
    const out = &stdout_file_out_stream.stream;

    var indentation: usize = 0;

    try out.print("const zang = @import(\"zang\");\n", .{});
    for (first_pass_result.modules) |module, i| {
        if (i < builtins.len) {
            continue;
        }

        const code_gen_result = code_gen_results[i];
        try out.print("\n", .{});
        try out.print("pub const {} = struct {{\n", .{module.name});
        indentation += 1;
        try indent(out, indentation);
        try out.print("pub const num_outputs = {};\n", .{code_gen_result.num_outputs});
        try indent(out, indentation);
        try out.print("pub const num_temps = {};\n", .{code_gen_result.num_temps});
        try indent(out, indentation);
        try out.print("pub const Params = struct {{\n", .{});
        indentation += 1;
        for (first_pass_result.module_params[module.first_param .. module.first_param + module.num_params]) |param| {
            const type_name = switch (param.param_type) {
                .boolean => "bool",
                .buffer => "[]const f32",
                .constant => "f32",
                .constant_or_buffer => "zang.ConstantOrBuffer",
                .one_of => |e| e.zig_name,
            };
            try indent(out, indentation);
            try out.print("{}: {},\n", .{ param.name, type_name });
        }
        indentation -= 1;
        try indent(out, indentation);
        try out.print("}};\n", .{});
        try out.print("\n", .{});
        for (first_pass_result.module_fields[module.first_field .. module.first_field + module.num_fields]) |field| {
            const module_name = first_pass_result.modules[field.resolved_module_index].zig_name;
            try indent(out, indentation);
            try out.print("{}: {},\n", .{ field.name, module_name });
        }
        for (code_gen_result.delays) |delay_decl, j| {
            try indent(out, indentation);
            try out.print("delay{}: zang.Delay({}),\n", .{ j, delay_decl.num_samples });
        }
        try out.print("\n", .{});
        try indent(out, indentation);
        try out.print("pub fn init() {} {{\n", .{module.name});
        indentation += 1;
        try indent(out, indentation);
        try out.print("return .{{\n", .{});
        indentation += 1;
        for (first_pass_result.module_fields[module.first_field .. module.first_field + module.num_fields]) |field| {
            const module_name = first_pass_result.modules[field.resolved_module_index].zig_name;
            try indent(out, indentation);
            try out.print(".{} = {}.init(),\n", .{ field.name, module_name });
        }
        for (code_gen_result.delays) |delay_decl, j| {
            try indent(out, indentation);
            try out.print(".delay{} = zang.Delay({}).init(),\n", .{ j, delay_decl.num_samples });
        }
        indentation -= 1;
        try indent(out, indentation);
        try out.print("}};\n", .{});
        indentation -= 1;
        try indent(out, indentation);
        try out.print("}}\n", .{});
        try out.print("\n", .{});
        try indent(out, indentation);
        try out.print("pub fn paint(self: *{}, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, params: Params) void {{\n", .{module.name});
        indentation += 1;
        var span: []const u8 = "span";
        for (code_gen_result.instructions) |instr| {
            switch (instr) {
                .copy_buffer => |x| {
                    try indent(out, indentation);
                    try out.print("zang.copy({}, temps[{}], ", .{ span, x.out_temp_buffer_index });
                    try printBufferValue(first_pass_result, module, out, x.in);
                    try out.print(");\n", .{});
                },
                .float_to_buffer => |x| {
                    try indent(out, indentation);
                    try out.print("zang.set({}, temps[{}], ", .{ span, x.out_temp_buffer_index });
                    try printFloatValue(first_pass_result, module, out, x.in);
                    try out.print(");\n", .{});
                },
                .arith_float_float => |x| {
                    try indent(out, indentation);
                    try out.print("const temp_float{}: f32 = ", .{x.out_temp_float_index});
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
                    try indent(out, indentation);
                    try out.print("zang.zero({}, temps[{}]);\n", .{ span, x.out_temp_buffer_index });
                    try indent(out, indentation);
                    switch (x.operator) {
                        .add => try out.print("zang.addScalar", .{}),
                        .mul => try out.print("zang.multiplyScalar", .{}),
                    }
                    try out.print("({}, temps[{}], ", .{ span, x.out_temp_buffer_index });
                    try printBufferValue(first_pass_result, module, out, x.a);
                    try out.print(", ", .{});
                    try printFloatValue(first_pass_result, module, out, x.b);
                    try out.print(");\n", .{});
                },
                .arith_buffer_buffer => |x| {
                    try indent(out, indentation);
                    try out.print("zang.zero({}, temps[{}]);\n", .{ span, x.out_temp_buffer_index });
                    try indent(out, indentation);
                    try out.print("zang.{}({}, temps[{}], ", .{
                        switch (x.operator) {
                            .add => @as([]const u8, "add"),
                            .mul => @as([]const u8, "multiply"),
                        },
                        span,
                        x.out_temp_buffer_index,
                    });
                    try printBufferValue(first_pass_result, module, out, x.a);
                    try out.print(", ", .{});
                    try printBufferValue(first_pass_result, module, out, x.b);
                    try out.print(");\n", .{});
                },
                .call => |call| {
                    const field = first_pass_result.module_fields[module.first_field + call.field_index];
                    try indent(out, indentation);
                    try out.print("zang.zero({}, temps[{}]);\n", .{ span, call.out_temp_buffer_index });
                    try indent(out, indentation);
                    try out.print("self.{}.paint({}, .{{temps[{}]}}, .{{", .{ field.name, span, call.out_temp_buffer_index });
                    // callee temps
                    for (call.temps) |n, j| {
                        if (j > 0) {
                            try out.print(", ", .{});
                        }
                        try out.print("temps[{}]", .{n});
                    }
                    // callee params
                    try out.print("}}, .{{\n", .{});
                    indentation += 1;
                    const callee_module = first_pass_result.modules[field.resolved_module_index];
                    const callee_params = first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];
                    for (call.args) |arg, j| {
                        const callee_param = callee_params[j];
                        try indent(out, indentation);
                        try out.print(".{} = ", .{callee_param.name});
                        if (callee_param.param_type == .constant_or_buffer) {
                            // coerce to ConstantOrBuffer?
                            switch (arg) {
                                .temp_buffer_weak => |index| try out.print("zang.buffer(temps[{}])", .{index}),
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
                    indentation -= 1;
                    try indent(out, indentation);
                    try out.print("}});\n", .{});
                },
                .delay_begin => |delay_begin| {
                    // this next line kind of sucks, if the delay loop iterates more than once,
                    // we'll have done some overlapping zeroing.
                    // maybe readDelayBuffer should do the zeroing internally.
                    try indent(out, indentation);
                    try out.print("zang.zero({}, temps[{}]);\n", .{ span, delay_begin.out_temp_buffer_index });
                    try indent(out, indentation);
                    try out.print("{{\n", .{});
                    indentation += 1;
                    try indent(out, indentation);
                    try out.print("var start = span.start;\n", .{});
                    try indent(out, indentation);
                    try out.print("const end = span.end;\n", .{});
                    try indent(out, indentation);
                    try out.print("while (start < end) {{\n", .{});
                    indentation += 1;
                    try indent(out, indentation);
                    try out.print("// temps[{}] will contain the delay buffer's previous contents\n", .{
                        delay_begin.feedback_temp_buffer_index,
                    });
                    try indent(out, indentation);
                    try out.print("zang.zero(zang.Span.init(start, end), temps[{}]);\n", .{
                        delay_begin.feedback_temp_buffer_index,
                    });
                    try indent(out, indentation);
                    try out.print("const samples_read = self.delay{}.readDelayBuffer(temps[{}][start..end]);\n", .{
                        delay_begin.delay_index,
                        delay_begin.feedback_temp_buffer_index,
                    });
                    try indent(out, indentation);
                    try out.print("const inner_span = zang.Span.init(start, start + samples_read);\n", .{});
                    span = "inner_span";
                    // FIXME script should be able to output separately into the delay buffer, and the final result.
                    // for now, i'm hardcoding it so that delay buffer is copied to final result, and the delay expression
                    // is sent to the delay buffer. i need some new syntax in the language before i can implement
                    // this properly
                    try out.print("\n", .{});
                    try indent(out, indentation);
                    try out.print("// copy the old delay buffer contents into the result (hardcoded for now)\n", .{});
                    try indent(out, indentation);
                    try out.print("zang.addInto({}, temps[{}], temps[{}]);\n", .{
                        span,
                        delay_begin.out_temp_buffer_index,
                        delay_begin.feedback_temp_buffer_index,
                    });
                    try out.print("\n", .{});
                    try indent(out, indentation);
                    try out.print("// inner expression\n", .{});
                },
                .delay_end => |delay_end| {
                    span = "span"; // nested delays aren't allowed so this is fine
                    try out.print("\n", .{});
                    try indent(out, indentation);
                    try out.print("// write expression result into the delay buffer\n", .{});
                    try indent(out, indentation);
                    try out.print("self.delay{}.writeDelayBuffer(", .{delay_end.delay_index});
                    try printBufferValue(first_pass_result, module, out, delay_end.inner_value);
                    try out.print("[start..start + samples_read]);\n", .{});
                    try indent(out, indentation);
                    try out.print("start += samples_read;\n", .{});
                    indentation -= 1;
                    try indent(out, indentation);
                    try out.print("}}\n", .{});
                    indentation -= 1;
                    try indent(out, indentation);
                    try out.print("}}\n", .{});
                },
                .output => |x| {
                    try indent(out, indentation);
                    try out.print("zang.addInto({}, outputs[0], ", .{span});
                    try printBufferValue(first_pass_result, module, out, x.value);
                    try out.print(");\n", .{});
                },
            }
        }
        indentation -= 1;
        try indent(out, indentation);
        try out.print("}}\n", .{});
        indentation -= 1;
        try indent(out, indentation);
        try out.print("}};\n", .{});
    }
}
