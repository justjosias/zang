const std = @import("std");
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const Module = @import("first_pass.zig").Module;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const ExpressionResult = @import("codegen.zig").ExpressionResult;
const BufferValue = @import("codegen.zig").BufferValue;
const FloatValue = @import("codegen.zig").FloatValue;
const BufferDest = @import("codegen.zig").BufferDest;

const State = struct {
    first_pass_result: FirstPassResult,
    module: ?Module,
    out: *std.io.OutStream(std.os.WriteError),
    indentation: usize,
    indent_next: bool,

    fn print(self: *State, comptime fmt: []const u8, args: var) !void {
        if (self.indent_next) {
            self.indent_next = false;
            if (fmt.len > 0 and fmt[0] == '}') {
                self.indentation -= 1;
            }
            var i: usize = 0;
            while (i < self.indentation) : (i += 1) {
                try self.out.print("    ", .{});
            }
        }
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

                if (comptime std.mem.eql(u8, arg_format, "bool")) {
                    try self.out.print("{}", .{@as(bool, arg)});
                } else if (comptime std.mem.eql(u8, arg_format, "f32")) {
                    try self.out.print("{d}", .{@as(f32, arg)});
                } else if (comptime std.mem.eql(u8, arg_format, "usize")) {
                    try self.out.print("{}", .{@as(usize, arg)});
                } else if (comptime std.mem.eql(u8, arg_format, "str")) {
                    try self.out.write(arg);
                } else if (comptime std.mem.eql(u8, arg_format, "module_name")) {
                    try self.printModuleName(arg);
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
        if (fmt.len >= 1 and fmt[fmt.len - 1] == '\n') {
            self.indent_next = true;
            if (fmt.len >= 2 and fmt[fmt.len - 2] == '{') {
                self.indentation += 1;
            }
        }
    }

    fn printModuleName(self: *State, module_index: usize) !void {
        const module = self.first_pass_result.modules[module_index];
        if (module.zig_package_name) |pkg_name| {
            try self.out.print("{}.", .{pkg_name});
        }
        try self.out.write(module.name);
    }

    fn printExpressionResult(self: *State, result: ExpressionResult) !void {
        const module = self.module orelse return error.NoModule;
        switch (result) {
            .nothing => unreachable,
            .temp_buffer_weak => |i| try self.print("temps[{usize}]", .{i}),
            .temp_buffer => |i| try self.print("temps[{usize}]", .{i}),
            .temp_float => |i| try self.print("temp_float{usize}", .{i}),
            .temp_bool => |i| try self.print("temp_bool{usize}", .{i}),
            .literal_boolean => |value| try self.print("{bool}", .{value}),
            .literal_number => |value| try self.print("{f32}", .{value}),
            .literal_enum_value => |str| try self.print(".{str}", .{str}),
            .self_param => |i| try self.print("params.{str}", .{self.first_pass_result.module_params[module.first_param + i].zig_name}),
        }
    }

    fn printBufferValue(self: *State, value: BufferValue) !void {
        const module = self.module orelse return error.NoModule;
        switch (value) {
            .temp_buffer_index => |i| try self.print("temps[{usize}]", .{i}),
            .self_param => |i| try self.print("params.{str}", .{self.first_pass_result.module_params[module.first_param + i].zig_name}),
        }
    }

    fn printBufferDest(self: *State, value: BufferDest) !void {
        switch (value) {
            .temp_buffer_index => |i| try self.print("temps[{usize}]", .{i}),
            .output_index => |i| try self.print("outputs[{usize}]", .{i}),
        }
    }

    fn printFloatValue(self: *State, value: FloatValue) !void {
        const module = self.module orelse return error.NoModule;
        switch (value) {
            .temp_float_index => |i| try self.print("temp_float{usize}", .{i}),
            .self_param => |i| try self.print("params.{str}", .{self.first_pass_result.module_params[module.first_param + i].zig_name}),
            .literal => |v| try self.print("{f32}", .{v}),
        }
    }
};

pub fn generateZig(first_pass_result: FirstPassResult, code_gen_results: []const CodeGenResult) !void {
    const stdout_file = std.io.getStdOut();
    var stdout_file_out_stream = stdout_file.outStream();

    var self: State = .{
        .first_pass_result = first_pass_result,
        .module = null,
        .out = &stdout_file_out_stream.stream,
        .indentation = 0,
        .indent_next = true,
    };

    try self.print("const std = @import(\"std\");\n", .{}); // for std.math.pow
    try self.print("const zang = @import(\"zang\");\n", .{});
    for (first_pass_result.builtin_packages) |pkg| {
        if (std.mem.eql(u8, pkg.zig_package_name, "zang")) {
            continue;
        }
        try self.print("const {str} = @import(\"{str}\");\n", .{ pkg.zig_package_name, pkg.zig_import_path });
    }

    const num_builtins = blk: {
        var n: usize = 0;
        for (first_pass_result.builtin_packages) |pkg| {
            n += pkg.builtins.len;
        }
        break :blk n;
    };

    for (first_pass_result.modules) |module, i| {
        if (i < num_builtins) {
            continue;
        }

        self.module = module;

        const code_gen_result = code_gen_results[i];
        try self.print("\n", .{});
        try self.print("pub const {str} = struct {{\n", .{module.name});
        try self.print("pub const num_outputs = {usize};\n", .{code_gen_result.num_outputs});
        try self.print("pub const num_temps = {usize};\n", .{code_gen_result.num_temps});
        try self.print("pub const Params = struct {{\n", .{});
        for (first_pass_result.module_params[module.first_param .. module.first_param + module.num_params]) |param| {
            const type_name = switch (param.param_type) {
                .boolean => "bool",
                .buffer => "[]const f32",
                .constant => "f32",
                .constant_or_buffer => "zang.ConstantOrBuffer",
               .one_of => |e| e.zig_name,
            };
            try self.print("{str}: {str},\n", .{ param.zig_name, type_name });
        }
        try self.print("}};\n", .{});
        try self.print("\n", .{});
        for (code_gen_result.fields) |field, j| {
            const field_module = first_pass_result.modules[field.resolved_module_index];
            try self.print("field{usize}_{str}: {module_name},\n", .{ j, field_module.name, field.resolved_module_index });
        }
        for (code_gen_result.delays) |delay_decl, j| {
            try self.print("delay{usize}: zang.Delay({usize}),\n", .{ j, delay_decl.num_samples });
        }
        try self.print("\n", .{});
        try self.print("pub fn init() {str} {{\n", .{module.name});
        try self.print("return .{{\n", .{});
        for (code_gen_result.fields) |field, j| {
            const field_module = first_pass_result.modules[field.resolved_module_index];
            try self.print(".field{usize}_{str} = {module_name}.init(),\n", .{ j, field_module.name, field.resolved_module_index });
        }
        for (code_gen_result.delays) |delay_decl, j| {
            try self.print(".delay{usize} = zang.Delay({usize}).init(),\n", .{ j, delay_decl.num_samples });
        }
        try self.print("}};\n", .{});
        try self.print("}}\n", .{});
        try self.print("\n", .{});
        try self.print("pub fn paint(self: *{str}, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, note_id_changed: bool, params: Params) void {{\n", .{module.name});
        var span: []const u8 = "span";
        for (code_gen_result.instructions) |instr| {
            switch (instr) {
                .copy_buffer => |x| {
                    try self.print("zang.copy({str}, {buffer_dest}, {buffer_value});\n", .{ span, x.out, x.in });
                },
                .float_to_buffer => |x| {
                    try self.print("zang.set({str}, {buffer_dest}, {float_value});\n", .{ span, x.out, x.in });
                },
                .cob_to_buffer => |x| {
                    const param = self.first_pass_result.module_params[module.first_param + x.in_self_param];
                    try self.print("switch (params.{str}) {{\n", .{param.zig_name});
                    try self.print(".constant => |v| zang.set({str}, {buffer_dest}, v),\n", .{ span, x.out });
                    try self.print(".buffer => |v| zang.copy({str}, {buffer_dest}, v),\n", .{ span, x.out });
                    try self.print("}}\n", {});
                },
                .negate_float_to_float => |x| {
                    try self.print("const temp_float{usize}: f32 = -{float_value};\n", .{ x.out_temp_float_index, x.a });
                },
                .negate_buffer_to_buffer => |x| {
                    try self.print("{{\n", .{});
                    try self.print("var i = {str}.start;\n", .{span});
                    try self.print("while (i < {str}.end) : (i += 1) {{\n", .{span});
                    try self.print("{buffer_dest}[i] = -{buffer_value}[i];\n", .{ x.out, x.a });
                    try self.print("}}\n", .{});
                    try self.print("}}\n", .{});
                },
                .arith_float_float => |x| {
                    try self.print("const temp_float{usize}: f32 = ", .{x.out_temp_float_index});
                    switch (x.operator) {
                        .add => try self.print("{float_value} + {float_value};\n", .{ x.a, x.b }),
                        .mul => try self.print("{float_value} * {float_value};\n", .{ x.a, x.b }),
                        .pow => try self.print("std.math.pow(f32, {float_value}, {float_value});\n", .{ x.a, x.b }),
                    }
                },
                .arith_float_buffer => |x| {
                    if (x.operator == .pow) {
                        try self.print("{{\n", .{});
                        try self.print("var i = {str}.start;\n", .{span});
                        try self.print("while (i < {str}.end) : (i += 1) {{\n", .{span});
                        try self.print("{buffer_dest}[i] = std.math.pow(f32, {float_value}, {buffer_value}[i]);\n", .{ x.out, x.a, x.b });
                        try self.print("}}\n", .{});
                        try self.print("}}\n", .{});
                    } else {
                        try self.print("zang.zero({str}, {buffer_dest});\n", .{ span, x.out });
                        switch (x.operator) {
                            .add => try self.print("zang.addScalar", .{}),
                            .mul => try self.print("zang.multiplyScalar", .{}),
                            .pow => unreachable,
                        }
                        // swap order, since the supported operators are commutative
                        try self.print("({str}, {buffer_dest}, {buffer_value}, {float_value});\n", .{ span, x.out, x.b, x.a });
                    }
                },
                .arith_buffer_float => |x| {
                    if (x.operator == .pow) {
                        try self.print("{{\n", .{});
                        try self.print("var i = {str}.start;\n", .{span});
                        try self.print("while (i < {str}.end) : (i += 1) {{\n", .{span});
                        try self.print("{buffer_dest}[i] = std.math.pow(f32, {buffer_value}[i], {float_value});\n", .{ x.out, x.a, x.b });
                        try self.print("}}\n", .{});
                        try self.print("}}\n", .{});
                    } else {
                        try self.print("zang.zero({str}, {buffer_dest});\n", .{ span, x.out });
                        switch (x.operator) {
                            .add => try self.print("zang.addScalar", .{}),
                            .mul => try self.print("zang.multiplyScalar", .{}),
                            .pow => unreachable,
                        }
                        try self.print("({str}, {buffer_dest}, {buffer_value}, {float_value});\n", .{ span, x.out, x.a, x.b });
                    }
                },
                .arith_buffer_buffer => |x| {
                    if (x.operator == .pow) {
                        try self.print("{{\n", .{});
                        try self.print("var i = {str}.start;\n", .{span});
                        try self.print("while (i < {str}.end) : (i += 1) {{\n", .{span});
                        try self.print("{buffer_dest}[i] = std.math.pow(f32, {buffer_value}[i], {buffer_value}[i]);\n", .{ x.out, x.a, x.b });
                        try self.print("}}\n", .{});
                        try self.print("}}\n", .{});
                    } else {
                        try self.print("zang.zero({str}, {buffer_dest});\n", .{ span, x.out });
                        switch (x.operator) {
                            .add => try self.print("zang.add", .{}),
                            .mul => try self.print("zang.multiply", .{}),
                            .pow => unreachable,
                        }
                        try self.print("({str}, {buffer_dest}, {buffer_value}, {buffer_value});\n", .{ span, x.out, x.a, x.b });
                    }
                },
                .call => |call| {
                    const field = code_gen_result.fields[call.field_index];
                    const field_module = first_pass_result.modules[field.resolved_module_index];
                    try self.print("zang.zero({str}, {buffer_dest});\n", .{ span, call.out });
                    try self.print("self.field{usize}_{str}.paint({str}, .{{", .{ call.field_index, field_module.name, span });
                    try self.print("{buffer_dest}}}, .{{", .{call.out});
                    // callee temps
                    for (call.temps) |n, j| {
                        if (j > 0) {
                            try self.print(", ", .{});
                        }
                        try self.print("temps[{usize}]", .{n});
                    }
                    // callee params
                    try self.print("}}, note_id_changed, .{{\n", .{});
                    const callee_module = first_pass_result.modules[field.resolved_module_index];
                    const callee_params = first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];
                    for (call.args) |arg, j| {
                        const callee_param = callee_params[j];
                        try self.print(".{str} = ", .{callee_param.zig_name});
                        if (callee_param.param_type == .constant_or_buffer) {
                            // coerce to ConstantOrBuffer?
                            switch (arg) {
                                .nothing => {},
                                .temp_buffer_weak => |index| try self.print("zang.buffer(temps[{usize}])", .{index}),
                                .temp_buffer => |index| try self.print("zang.buffer(temps[{usize}])", .{index}),
                                .temp_float => |index| try self.print("zang.constant(temp_float{usize})", .{index}),
                                .temp_bool => unreachable,
                                .literal_boolean => unreachable,
                                .literal_number => |value| try self.print("zang.constant({f32})", .{value}),
                                .literal_enum_value => unreachable,
                                .self_param => |index| {
                                    const param = first_pass_result.module_params[module.first_param + index];
                                    switch (param.param_type) {
                                        .boolean => unreachable,
                                        .buffer => try self.print("zang.buffer(params.{str})", .{param.zig_name}),
                                        .constant => try self.print("zang.constant(params.{str})", .{param.zig_name}),
                                        .constant_or_buffer => try self.print("params.{str}", .{param.zig_name}),
                                        .one_of => unreachable,
                                    }
                                },
                            }
                        } else {
                            try self.print("{expression_result}", .{arg});
                        }
                        try self.print(",\n", .{});
                    }
                    try self.print("}});\n", .{});
                },
                .delay_begin => |delay_begin| {
                    // this next line kind of sucks, if the delay loop iterates more than once,
                    // we'll have done some overlapping zeroing.
                    // maybe readDelayBuffer should do the zeroing internally.
                    try self.print("zang.zero({str}, {buffer_dest});\n", .{ span, delay_begin.out });
                    try self.print("{{\n", .{});
                    try self.print("var start = span.start;\n", .{});
                    try self.print("const end = span.end;\n", .{});
                    try self.print("while (start < end) {{\n", .{});
                    try self.print("// temps[{usize}] will be the destination for writing into the feedback buffer\n", .{
                        delay_begin.feedback_out_temp_buffer_index,
                    });
                    try self.print("zang.zero(zang.Span.init(start, end), temps[{usize}]);\n", .{
                        delay_begin.feedback_out_temp_buffer_index,
                    });
                    try self.print("// temps[{usize}] will contain the delay buffer's previous contents\n", .{
                        delay_begin.feedback_temp_buffer_index,
                    });
                    try self.print("zang.zero(zang.Span.init(start, end), temps[{usize}]);\n", .{
                        delay_begin.feedback_temp_buffer_index,
                    });
                    try self.print("const samples_read = self.delay{usize}.readDelayBuffer(temps[{usize}][start..end]);\n", .{
                        delay_begin.delay_index,
                        delay_begin.feedback_temp_buffer_index,
                    });
                    try self.print("const inner_span = zang.Span.init(start, start + samples_read);\n", .{});
                    span = "inner_span";
                    // FIXME script should be able to output separately into the delay buffer, and the final result.
                    // for now, i'm hardcoding it so that delay buffer is copied to final result, and the delay expression
                    // is sent to the delay buffer. i need some new syntax in the language before i can implement
                    // this properly
                    try self.print("\n", .{});

                    //try indent(out, indentation);
                    //try out.print("// copy the old delay buffer contents into the result (hardcoded for now)\n", .{});

                    //try indent(out, indentation);
                    //try out.print("zang.addInto({str}, ", .{span});
                    //try printBufferDest(out, delay_begin.out);
                    //try out.print(", temps[{usize}]);\n", .{delay_begin.feedback_temp_buffer_index});
                    //try out.print("\n", .{});

                    try self.print("// inner expression\n", .{});
                },
                .delay_end => |delay_end| {
                    span = "span"; // nested delays aren't allowed so this is fine
                    try self.print("\n", .{});
                    try self.print("// write expression result into the delay buffer\n", .{});
                    try self.print("self.delay{usize}.writeDelayBuffer(temps[{usize}][start..start + samples_read]);\n", .{
                        delay_end.delay_index,
                        delay_end.feedback_out_temp_buffer_index,
                    });
                    try self.print("start += samples_read;\n", .{});
                    try self.print("}}\n", .{});
                    try self.print("}}\n", .{});
                },
            }
        }
        try self.print("}}\n", .{});
        try self.print("}};\n", .{});
    }

    std.debug.assert(self.indentation == 0);
}
