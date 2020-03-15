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
                .call => |call| {
                    const callee_module = module_def.fields.span()[call.field_index].resolved_module;
                    switch (call.result_loc) {
                        .temp => |n| try out.print("        zang.zero(span, temps[{}]);\n", .{n}),
                        .output => |n| try out.print("        zang.zero(span, outputs[{}]);\n", .{n}),
                    }
                    try out.print("        self.{}.paint(span, ", .{
                        module_def.fields.span()[call.field_index].name,
                    });
                    // callee outputs
                    switch (call.result_loc) {
                        .temp => |n| try out.print(".{{temps[{}]}}", .{n}),
                        .output => |n| try out.print(".{{outputs[{}]}}", .{n}),
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
                    for (call.args.span()) |arg, i| {
                        try out.print("            .{} = ", .{callee_module.params[i].name});
                        switch (arg) {
                            .temp => |v| {
                                try out.print("temps[{}]", .{v});
                            },
                            .literal => |literal| {
                                switch (literal) {
                                    .boolean => |v| try out.print("{}", .{v}),
                                    .constant => |v| try out.print("{d}", .{v}),
                                    .constant_or_buffer => |v| try out.print("zang.constant({d})", .{v}),
                                }
                            },
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

pub const BuiltinInstance = union(enum) {
    pulse_osc: *zang.PulseOsc,
    tri_saw_osc: *zang.TriSawOsc,
};

pub const Instance = union(enum) {
    builtin: BuiltinInstance,
    script_module: void,
};

pub fn ScriptModule(comptime ParamsType: type) type {
    return struct {
        pub const num_outputs = 1; // FIXME
        pub const num_temps = 0; // FIXME
        pub const Params = ParamsType;

        module_defs: []const ModuleDef,
        module_def: *const ModuleDef,
        param_lookup: [@typeInfo(Params).Struct.fields.len]usize,

        instances: []Instance,

        pub fn init(module_defs: []const ModuleDef, module_def: *const ModuleDef, allocator: *std.mem.Allocator) !@This() {
            var self: @This() = .{
                .module_defs = module_defs,
                .module_def = module_def,
                .param_lookup = undefined,
                .instances = undefined,
            };
            // instantiate fields
            self.instances = try allocator.alloc(Instance, module_def.fields.span().len);
            for (module_def.fields.span()) |field, i| {
                //switch (field.resolved_type) {
                //    .builtin_module => |mod_ptr| {
                //        if (std.mem.eql(u8, mod_ptr.name, "PulseOsc")) {
                //            const mod = try allocator.create(zang.PulseOsc);
                //            mod.* = zang.PulseOsc.init();
                //            self.instances[i] = .{ .builtin = .{ .pulse_osc = mod } };
                //        } else if (std.mem.eql(u8, mod_ptr.name, "TriSawOsc")) {
                //            const mod = try allocator.create(zang.TriSawOsc);
                //            mod.* = zang.TriSawOsc.init();
                //            self.instances[i] = .{ .builtin = .{ .tri_saw_osc = mod } };
                //        } else {
                //            unreachable;
                //        }
                //    },
                //    .script_module => |module_index| {
                //        // TODO how do i instantiate other script modules?
                //        // i need another ScriptModule class, but not generic. or this generic one should be a wrapper around that.
                //        unreachable;
                //    },
                //}
            }
            // verify that ParamsType is compatible with the script's params
            // TODO detect params in the module def that are not set in `params`. this should be an error
            inline for (@typeInfo(Params).Struct.fields) |field, field_index| {
                var maybe_param: ?ModuleParam = null;
                var maybe_param_index: usize = undefined;
                for (self.module_def.resolved.params) |param, param_index| {
                    if (std.mem.eql(u8, param.name, field.name)) {
                        maybe_param = param;
                        maybe_param_index = param_index;
                    }
                }
                if (maybe_param) |param| {
                    try checkParamType(param, field.field_type);
                    self.param_lookup[field_index] = maybe_param_index;
                } else {
                    std.debug.warn("WARNING: discarding param `{}`\n", .{field.name});
                }
            }
            return self;
        }

        // TODO - deinit

        fn checkParamType(param: ModuleParam, comptime field_type: type) !void {
            switch (param.param_type) {
                .boolean => {
                    if (field_type != bool) {
                        std.debug.warn("ERROR: type mismatch\n", .{});
                        return error.Failed;
                    }
                },
                .constant => {
                    if (field_type != f32) {
                        std.debug.warn("ERROR: type mismatch\n", .{});
                        return error.Failed;
                    }
                },
                .constant_or_buffer => {
                    if (field_type != zang.ConstantOrBuffer) {
                        std.debug.warn("ERROR: type mismatch\n", .{});
                        return error.Failed;
                    }
                },
            }
        }

        pub fn paint(self: *@This(), span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, params: Params) void {
            for (self.module_def.resolved.params) |param, param_index| {
                inline for (@typeInfo(Params).Struct.fields) |field, field_index| {
                    if (self.param_lookup[field_index] == param_index) {
                        std.debug.warn("set param `{}` to {}\n", .{ param.name, @field(params, field.name) });
                    }
                }
            }

            //switch (self.module_def.expression) {
            //    .call => |call| {
            //        const instance = self.instances[call.field_index];
            //        const field = &self.module_def.fields.span()[call.field_index];
            //        switch (field.resolved_type) {
            //            .builtin_module => |mod_ptr| {
            //                if (std.mem.eql(u8, mod_ptr.name, "PulseOsc")) {
            //                    switch (instance) {
            //                        .builtin => |builtin| {
            //                            switch (builtin) {
            //                                .pulse_osc => |mod| {
            //                                    // TODO manage outputs and temps
            //                                    var sub_params: zang.PulseOsc.Params = undefined;
            //                                    for (call.args.span()) |arg| {
            //                                        if (std.mem.eql(u8, arg.arg_name, "sample_rate")) {
            //                                            sub_params.sample_rate = arg.value;
            //                                        }
            //                                        if (std.mem.eql(u8, arg.arg_name, "freq")) {
            //                                            sub_params.freq = zang.constant(arg.value);
            //                                        }
            //                                        if (std.mem.eql(u8, arg.arg_name, "color")) {
            //                                            sub_params.color = arg.value;
            //                                        }
            //                                    }
            //                                    mod.paint(span, outputs, temps, sub_params);
            //                                },
            //                                else => unreachable,
            //                            }
            //                        },
            //                        .script_module => unreachable,
            //                    }
            //                } else if (std.mem.eql(u8, mod_ptr.name, "TriSawOsc")) {
            //                    switch (instance) {
            //                        .builtin => |builtin| {
            //                            switch (builtin) {
            //                                .tri_saw_osc => |mod| {
            //                                    // TODO manage outputs and temps
            //                                    var sub_params: zang.TriSawOsc.Params = undefined;
            //                                    for (call.args.span()) |arg| {
            //                                        if (std.mem.eql(u8, arg.arg_name, "sample_rate")) {
            //                                            sub_params.sample_rate = arg.value;
            //                                        }
            //                                        if (std.mem.eql(u8, arg.arg_name, "freq")) {
            //                                            sub_params.freq = zang.constant(arg.value);
            //                                        }
            //                                        if (std.mem.eql(u8, arg.arg_name, "color")) {
            //                                            sub_params.color = arg.value;
            //                                        }
            //                                    }
            //                                    mod.paint(span, outputs, temps, sub_params);
            //                                },
            //                                else => unreachable,
            //                            }
            //                        },
            //                        .script_module => unreachable,
            //                    }
            //                } else {
            //                    unreachable;
            //                }
            //            },
            //            .script_module => |module_index| {
            //                // TODO need an instance of it
            //                const mod = &self.module_defs[module_index];
            //                switch (instance) {
            //                    .builtin => unreachable,
            //                    .script_module => {
            //                        // ...
            //                    },
            //                }
            //                unreachable;
            //            },
            //        }
            //    },
            //    .nothing => {},
            //}
        }
    };
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
    // try to do stuff at runtime (unrelated to generated zig source)
    const Params = struct {
        freq: f32,
        color: f32,
        note_on: bool,
    };
    var mod = ScriptModule(Params).init(script.module_defs, &script.module_defs[0], allocator) catch return 1;
    // TODO defer mod deinit
    var output: [1024]f32 = undefined;
    zang.zero(zang.Span.init(0, 1024), &output);
    mod.paint(
        zang.Span.init(0, 1024),
        .{&output},
        .{},
        .{ .freq = 440.0, .color = 0.5, .note_on = true },
    );
    //var i: usize = 0;
    //while (i < 100) : (i += 1) {
    //    std.debug.warn("{d}\n", .{output[i]});
    //}
    return 0;
}
