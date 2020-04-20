const std = @import("std");
const PrintHelper = @import("print_helper.zig").PrintHelper;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const Module = @import("first_pass.zig").Module;
const ModuleCodeGen = @import("codegen.zig").ModuleCodeGen;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const ExpressionResult = @import("codegen.zig").ExpressionResult;
const BufferValue = @import("codegen.zig").BufferValue;
const FloatValue = @import("codegen.zig").FloatValue;
const BufferDest = @import("codegen.zig").BufferDest;

const State = struct {
    first_pass_result: FirstPassResult,
    module: ?Module,
    helper: PrintHelper,

    pub fn print(self: *State, comptime fmt: []const u8, args: var) !void {
        try self.helper.print(self, fmt, args);
    }

    pub fn printArgValue(self: *State, comptime arg_format: []const u8, arg: var) !void {
        if (comptime std.mem.eql(u8, arg_format, "identifier")) {
            try self.printIdentifier(arg);
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
    }

    fn printIdentifier(self: *State, string: []const u8) !void {
        if (std.zig.Token.getKeyword(string) != null) {
            try self.print("@\"{str}\"", .{string});
        } else {
            try self.print("{str}", .{string});
        }
    }

    fn printModuleName(self: *State, module_index: usize) !void {
        const module = self.first_pass_result.modules[module_index];
        if (module.zig_package_name) |pkg_name| {
            try self.print("{identifier}.", .{pkg_name});
        }
        try self.print("{identifier}", .{module.name});
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
            .literal_enum_value => |str| try self.print(".{identifier}", .{str}),
            .self_param => |i| try self.print("params.{identifier}", .{module.params[i].name}),
        }
    }

    fn printBufferValue(self: *State, value: BufferValue) !void {
        const module = self.module orelse return error.NoModule;
        switch (value) {
            .temp_buffer_index => |i| try self.print("temps[{usize}]", .{i}),
            .self_param => |i| try self.print("params.{identifier}", .{module.params[i].name}),
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
            .self_param => |i| try self.print("params.{identifier}", .{module.params[i].name}),
            .literal => |v| try self.print("{f32}", .{v}),
        }
    }
};

pub fn generateZig(first_pass_result: FirstPassResult, codegen_result: CodeGenResult) !void {
    const stdout_file = std.io.getStdOut();
    var stdout_file_out_stream = stdout_file.outStream();

    var self: State = .{
        .first_pass_result = first_pass_result,
        .module = null,
        .helper = PrintHelper.init(&stdout_file_out_stream),
    };
    defer self.helper.deinit();

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

        const module_result = codegen_result.module_results[i];
        try self.print("\n", .{});
        try self.print("pub const {identifier} = struct {{\n", .{module.name});
        try self.print("pub const num_outputs = {usize};\n", .{module_result.num_outputs});
        try self.print("pub const num_temps = {usize};\n", .{module_result.num_temps});
        try self.print("pub const Params = struct {{\n", .{});
        for (module.params) |param| {
            const type_name = switch (param.param_type) {
                .boolean => "bool",
                .buffer => "[]const f32",
                .constant => "f32",
                .constant_or_buffer => "zang.ConstantOrBuffer",
                .one_of => |e| e.zig_name,
            };
            try self.print("{identifier}: {str},\n", .{ param.name, type_name });
        }
        try self.print("}};\n", .{});
        try self.print("\n", .{});
        for (module_result.fields) |field, j| {
            const field_module = first_pass_result.modules[field.resolved_module_index];
            try self.print("field{usize}_{identifier}: {module_name},\n", .{ j, field_module.name, field.resolved_module_index });
        }
        for (module_result.delays) |delay_decl, j| {
            try self.print("delay{usize}: zang.Delay({usize}),\n", .{ j, delay_decl.num_samples });
        }
        try self.print("\n", .{});
        try self.print("pub fn init() {identifier} {{\n", .{module.name});
        try self.print("return .{{\n", .{});
        for (module_result.fields) |field, j| {
            const field_module = first_pass_result.modules[field.resolved_module_index];
            try self.print(".field{usize}_{identifier} = {module_name}.init(),\n", .{ j, field_module.name, field.resolved_module_index });
        }
        for (module_result.delays) |delay_decl, j| {
            try self.print(".delay{usize} = zang.Delay({usize}).init(),\n", .{ j, delay_decl.num_samples });
        }
        try self.print("}};\n", .{});
        try self.print("}}\n", .{});
        try self.print("\n", .{});
        try self.print("pub fn paint(self: *{identifier}, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, note_id_changed: bool, params: Params) void {{\n", .{module.name});
        var span: []const u8 = "span";
        for (module_result.instructions) |instr| {
            switch (instr) {
                .copy_buffer => |x| {
                    try self.print("zang.copy({str}, {buffer_dest}, {buffer_value});\n", .{ span, x.out, x.in });
                },
                .float_to_buffer => |x| {
                    try self.print("zang.set({str}, {buffer_dest}, {float_value});\n", .{ span, x.out, x.in });
                },
                .cob_to_buffer => |x| {
                    try self.print("switch (params.{identifier}) {{\n", .{module.params[x.in_self_param].name});
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
                    const field = module_result.fields[call.field_index];
                    const field_module = first_pass_result.modules[field.resolved_module_index];
                    try self.print("zang.zero({str}, {buffer_dest});\n", .{ span, call.out });
                    try self.print("self.field{usize}_{identifier}.paint({str}, .{{", .{ call.field_index, field_module.name, span });
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
                    for (call.args) |arg, j| {
                        const callee_param = callee_module.params[j];
                        try self.print(".{identifier} = ", .{callee_param.name});
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
                                    const param = module.params[index];
                                    switch (param.param_type) {
                                        .boolean => unreachable,
                                        .buffer => try self.print("zang.buffer(params.{identifier})", .{param.name}),
                                        .constant => try self.print("zang.constant(params.{identifier})", .{param.name}),
                                        .constant_or_buffer => try self.print("params.{identifier}", .{param.name}),
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
}
