const std = @import("std");
const zang = @import("zang");
const Source = @import("common.zig").Source;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const tokenize = @import("tokenizer.zig").tokenize;
const ModuleDef = @import("first_pass.zig").ModuleDef;
const ModuleParamDecl = @import("first_pass.zig").ModuleParamDecl;
const firstPass = @import("first_pass.zig").firstPass;
const secondPass = @import("second_pass.zig").secondPass;

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

    try secondPass(source, tokens, result.module_defs);

    return Script {
        .module_defs = result.module_defs,
    };
}

pub fn ScriptModule(comptime ParamsType: type) type {
    return struct {
        pub const num_outputs = 1; // FIXME
        pub const num_temps = 0; // FIXME
        pub const Params = ParamsType;

        module_def: *const ModuleDef,
        param_lookup: [@typeInfo(Params).Struct.fields.len]usize,

        pub fn init(module_def: *const ModuleDef) !@This() {
            var self: @This() = .{
                .module_def = module_def,
                .param_lookup = undefined,
            };
            // TODO detect params in the module def that are not set in `params`. this should be an error
            inline for (@typeInfo(Params).Struct.fields) |field, field_index| {
                var maybe_param: ?*const ModuleParamDecl = null;
                var maybe_param_index: usize = undefined;
                for (self.module_def.params.span()) |*param, param_index| {
                    if (std.mem.eql(u8, param.name, field.name)) {
                        maybe_param = param;
                        maybe_param_index = param_index;
                    }
                }
                if (maybe_param) |param| {
                    try checkParamType(param, field.field_type);
                    self.param_lookup[field_index] = maybe_param_index;
                } else {
                    std.debug.warn("WARNING: discarding param `{}`\n", .{ field.name });
                }
            }
            return self;
        }

        fn checkParamType(param: *const ModuleParamDecl, comptime field_type: type) !void {
            switch (param.resolved_type) {
                .boolean => {
                    if (field_type != bool) {
                        std.debug.warn("ERROR: type mismatch\n", .{});
                        return error.Failed;
                    }
                },
                .number => {
                    if (field_type != f32) {
                        std.debug.warn("ERROR: type mismatch\n", .{});
                        return error.Failed;
                    }
                },
            }
        }

        pub fn paint(self: *@This(), span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, params: Params) void {
            for (self.module_def.params.span()) |*param, param_index| {
                inline for (@typeInfo(Params).Struct.fields) |field, field_index| {
                    if (self.param_lookup[field_index] == param_index) {
                        std.debug.warn("set param `{}` to {}\n", .{ param.name, @field(params, field.name) });
                    }
                }
            }
            //const output = outputs[0];
            //var i = span.start; while (i < span.end) : (i += 1) {
            //    const a = std.math.atan(params.input[i] * gain1 + offs);
            //    output[i] += gain2 * a;
            //}
        }
    };
}

pub fn main() u8 {
    const allocator = std.heap.page_allocator;
    const script = loadScript("../../script.txt", allocator) catch return 1;
    // TODO defer script deinit
    const Params = struct {
        freq: f32,
        color: f32,
        note_on: bool,
    };
    var mod = ScriptModule(Params).init(&script.module_defs[0]) catch return 1;
    var output: [1024]f32 = undefined;
    mod.paint(
        zang.Span.init(0, 1024),
        .{ &output },
        .{},
        .{
            .freq = 440.0,
            .color = 0.5,
            .note_on = true,
        },
    );
    return 0;
}
