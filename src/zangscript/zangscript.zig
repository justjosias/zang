const std = @import("std");
const zang = @import("zang");
const Source = @import("common.zig").Source;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const tokenize = @import("tokenizer.zig").tokenize;
const ModuleDef = @import("first_pass.zig").ModuleDef;
const ModuleParam = @import("first_pass.zig").ModuleParam;
const ModuleParamDecl = @import("first_pass.zig").ModuleParamDecl;
const firstPass = @import("first_pass.zig").firstPass;
const secondPass = @import("second_pass.zig").secondPass;

comptime {
    _ = @import("builtins.zig").builtins;
}

// goal: parse a file and be able to run it at runtime.
// but design the scripting syntax so that it would also be possible to
// compile it statically.
//
// this should be another module type like "mod_script.zig"
// the module encapsulates all the runtime stuff but has the same outer API
// surface (e.g. paint method) as any other module.
// the tricky bit is that it won't have easily accessible params...?
// and i guess it will need an allocator for its temps?

// to use a script module from zig code, you must provide a Params type that's
// compatible with the script.
// script module will come up with its own number of required temps, and you'll
// need to provide those, too. it will be known only at runtime, i think.

pub const Script = struct {
    module_defs: []const ModuleDef,
};

pub fn loadScript(comptime filename: []const u8, allocator: *std.mem.Allocator) !Script {
    const source: Source = .{
        .filename = filename,
        .contents = @embedFile(filename),
    };

    var tokenizer: Tokenizer = .{
        .source = source,
        .error_message = null,
        .tokens = std.ArrayList(Token).init(allocator),
    };
    defer tokenizer.tokens.deinit();
    try tokenize(&tokenizer);
    const tokens = tokenizer.tokens.span();

    var result = try firstPass(source, tokens, allocator);
    defer {
        // FIXME deinit fields
        //result.module_defs.deinit();
    }

    try secondPass(source, tokens, result.module_defs, allocator);

    return Script{
        .module_defs = result.module_defs,
    };
}

pub fn generateCode(script: Script) !void {
    const stdout_file = std.io.getStdOut();
    var stdout_file_out_stream = stdout_file.outStream();
    const out = &stdout_file_out_stream.stream;

    try out.print("const zang = @import(\"zang\");\n", .{});
    for (script.module_defs) |module_def| {
        try out.print("\n", .{});
        try out.print("pub const {} = struct {{\n", .{module_def.name});
        try out.print("    pub const num_outputs = {};\n", .{module_def.resolved.num_outputs});
        try out.print("    pub const num_temps = {};\n", .{module_def.resolved.num_temps});
        try out.print("    pub const Params = struct {{\n", .{});
        for (module_def.resolved.params) |param| {
            const type_name = switch (param.param_type) {
                .boolean => "bool",
                .constant => "f32",
                .constant_or_buffer => "zang.ConstantOrBuffer",
            };
            try out.print("        {}: {},\n", .{ param.name, type_name });
        }
        try out.print("    }};\n", .{});
        try out.print("\n", .{});
        for (module_def.fields.span()) |field| {
            try out.print("    {}: {},\n", .{ field.name, field.resolved_module.zig_name });
        }
        try out.print("\n", .{});
        try out.print("    pub fn init() {} {{\n", .{module_def.name});
        try out.print("        return .{{\n", .{});
        for (module_def.fields.span()) |field| {
            try out.print("            .{} = {}.init(),\n", .{ field.name, field.resolved_module.zig_name });
        }
        try out.print("        }};\n", .{});
        try out.print("    }}\n", .{});
        try out.print("\n", .{});
        try out.print("    pub fn paint(self: *{}, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, params: Params) void {{\n", .{module_def.name});
        for (module_def.instructions) |instr| {
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
                        module_def.resolved.params[x.param_index].name,
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
                    const callee_module = module_def.fields.span()[call.field_index].resolved_module;
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
                    try out.print("        self.{}.paint(span, ", .{
                        module_def.fields.span()[call.field_index].name,
                    });
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
                    for (call.temps.span()) |n, i| {
                        if (i > 0) {
                            try out.print(", ", .{});
                        }
                        try out.print("temps[{}]", .{n});
                    }
                    // callee params
                    try out.print("}}, .{{\n", .{});
                    for (call.args) |arg, i| {
                        const param = &callee_module.params[i];
                        try out.print("            .{} = ", .{callee_module.params[i].name});
                        switch (arg) {
                            .temp => |v| {
                                if (param.param_type == .constant_or_buffer) {
                                    try out.print("zang.buffer(temps[{}])", .{v});
                                } else {
                                    unreachable;
                                }
                            },
                            .temp_float => |n| {
                                if (param.param_type == .constant_or_buffer) {
                                    try out.print("zang.constant(temp_float{})", .{n});
                                } else if (param.param_type == .constant) {
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

pub fn main() u8 {
    const allocator = std.heap.page_allocator;
    const script = loadScript("../../script.txt", allocator) catch return 1;
    // TODO defer script deinit
    // generate zig source
    generateCode(script) catch |err| {
        std.debug.warn("{}\n", .{err});
        return 1;
    };
    return 0;
}
