const std = @import("std");
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const builtins = @import("builtins.zig").builtins;

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
                .constant => "f32",
                .constant_or_buffer => "zang.ConstantOrBuffer",
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
                .load_constant => |x| {
                    try out.print("        const temp_float{}: f32 = {d};\n", .{ x.out_index, x.value });
                },
                .load_boolean => |x| {
                    try out.print("        const temp_bool{} = {};\n", .{ x.out_index, x.value });
                },
                .float_to_buffer => |x| {
                    switch (x.out) {
                        .temp => |n| try out.print("        zang.set(span, temps[{}], temp_float{});\n", .{ n, x.in_temp_float }),
                        .output => |n| try out.print("        zang.set(span, outputs[{}], temp_float{});\n", .{ n, x.in_temp_float }),
                    }
                },
                .load_param_float => |x| {
                    try out.print("        const temp_float{}: f32 = params.{};\n", .{
                        x.out_temp_float,
                        first_pass_result.module_params[module.first_param + x.param_index].name,
                    });
                },
                .arith_float_float => |x| {
                    try out.print("        const temp_float{}: f32 = temp_float{} {} temp_float{};\n", .{
                        x.out_temp_float,
                        x.a_temp_float,
                        switch (x.operator) {
                            .add => "+",
                            .multiply => "*",
                        },
                        x.b_temp_float,
                    });
                },
                .arith_buffer_float => |x| {
                    switch (x.out) {
                        .temp => |n| {
                            try out.print("        zang.zero(span, temps[{}]);\n", .{n});
                            try out.print("        zang.", .{});
                            switch (x.operator) {
                                .add => try out.print("add", .{}),
                                .multiply => try out.print("multiply", .{}),
                            }
                            try out.print("Scalar(span, temps[{}], temps[{}], temp_float{});\n", .{
                                n,
                                x.temp_index,
                                x.temp_float_index,
                            });
                        },
                        .output => |n| {
                            try out.print("        zang.zero(span, outputs[{}]);\n", .{n});
                            try out.print("        zang.", .{});
                            switch (x.operator) {
                                .add => try out.print("add", .{}),
                                .multiply => try out.print("multiply", .{}),
                            }
                            try out.print("Scalar(span, outputs[{}], temps[{}], temp_float{});\n", .{
                                n,
                                x.temp_index,
                                x.temp_float_index,
                            });
                        },
                    }
                },
                .call => |call| {
                    const field = first_pass_result.module_fields[module.first_field + call.field_index];
                    switch (call.result_loc) {
                        .buffer => |buffer_loc| {
                            switch (buffer_loc) {
                                .output => |n| try out.print("        zang.zero(span, outputs[{}]);\n", .{n}),
                                .temp => |n| try out.print("        zang.zero(span, temps[{}]);\n", .{n}),
                            }
                        },
                        .temp_float => {},
                        .temp_bool => {},
                    }
                    try out.print("        self.{}.paint(span, ", .{field.name});
                    // callee outputs
                    switch (call.result_loc) {
                        .buffer => |buffer_loc| {
                            switch (buffer_loc) {
                                .output => |n| try out.print(".{{outputs[{}]}}", .{n}),
                                .temp => |n| try out.print(".{{temps[{}]}}", .{n}),
                            }
                        },
                        .temp_float => unreachable,
                        .temp_bool => unreachable,
                    }
                    // callee temps
                    try out.print(", .{{", .{});
                    for (call.temps.span()) |n, j| {
                        if (j > 0) {
                            try out.print(", ", .{});
                        }
                        try out.print("temps[{}]", .{n});
                    }
                    // callee params
                    try out.print("}}, .{{\n", .{});
                    const callee_params = blk: {
                        const callee_module = first_pass_result.modules[field.resolved_module_index];
                        break :blk first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];
                    };
                    for (call.args) |arg, j| {
                        const callee_param = callee_params[j];
                        try out.print("            .{} = ", .{callee_param.name});
                        switch (arg) {
                            .temp => |v| {
                                if (callee_param.param_type == .constant_or_buffer) {
                                    try out.print("zang.buffer(temps[{}])", .{v});
                                } else {
                                    unreachable;
                                }
                            },
                            .temp_float => |n| {
                                if (callee_param.param_type == .constant_or_buffer) {
                                    try out.print("zang.constant(temp_float{})", .{n});
                                } else if (callee_param.param_type == .constant) {
                                    try out.print("temp_float{}", .{n});
                                } else {
                                    unreachable;
                                }
                            },
                            .temp_bool => |n| {
                                try out.print("temp_bool{}", .{n});
                            },
                            //.literal => |literal| {
                            //    // TODO don't do coercion here, do it in codegen.zig.
                            //    switch (literal) {
                            //        .boolean => |v| try out.print("{}", .{v}),
                            //        .constant => |v| {
                            //            if (callee_module.params[i].param_type == .constant_or_buffer) {
                            //                try out.print("zang.constant({d})", .{v});
                            //            } else {
                            //                try out.print("{d}", .{v});
                            //            }
                            //        },
                            //        .constant_or_buffer => {
                            //            // literal cannot have this type
                            //            unreachable;
                            //        },
                            //    }
                            //},
                            //.self_param => |param_index| {
                            //    const param = &module_def.resolved.params[param_index];
                            //    if (callee_module.params[i].param_type == .constant_or_buffer and param.param_type == .constant) {
                            //        try out.print("zang.constant(params.{})", .{param.name});
                            //    } else {
                            //        try out.print("params.{}", .{param.name});
                            //    }
                            //},
                        }
                        try out.print(",\n", .{});
                    }
                    try out.print("        }});\n", .{});
                },
            }
        }
        try out.print("    }}\n", .{});
        try out.print("}};\n", .{});
    }
}
