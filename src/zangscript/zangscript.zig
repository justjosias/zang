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
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const generateZig = @import("codegen_zig.zig").generateZig;

comptime {
    _ = @import("builtins.zig").builtins; // ?
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
    code_gen_results: []const CodeGenResult,
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

    const code_gen_results = try secondPass(source, tokens, result, allocator);

    return Script{
        .module_defs = result.module_defs,
        .code_gen_results = code_gen_results,
    };
}

pub fn main() u8 {
    const allocator = std.heap.page_allocator;
    const script = loadScript("../../script.txt", allocator) catch return 1;
    // TODO defer script deinit
    // generate zig source
    generateZig(script.module_defs, script.code_gen_results) catch |err| {
        std.debug.warn("{}\n", .{err});
        return 1;
    };
    return 0;
}
