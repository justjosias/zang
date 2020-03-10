const std = @import("std");
const Source = @import("common.zig").Source;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const tokenize = @import("tokenizer.zig").tokenize;
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

pub fn main() u8 {
    const allocator = std.heap.page_allocator;

    const source: Source = .{
        .filename = "script.txt",
        .contents = @embedFile("../../script.txt"),
    };

    // tokenize
    var tokenizer: Tokenizer = .{
        .source = source,
        .error_message = null,
        .tokens = std.ArrayList(Token).init(allocator),
    };
    defer tokenizer.tokens.deinit();
    tokenize(&tokenizer) catch return 1;
    const tokens = tokenizer.tokens.span();

    // first pass: parse module definitions (but not paint procedures)
    var result = firstPass(source, tokens, allocator) catch return 1;
    defer {
        // FIXME deinit fields
        //result.module_defs.deinit();
    }

    // second pass: parse module paint procedures
    secondPass(source, tokens, result.module_defs) catch return 1;
    return 0;
}
