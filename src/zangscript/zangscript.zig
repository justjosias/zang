const std = @import("std");
const Source = @import("common.zig").Source;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const tokenize = @import("tokenizer.zig").tokenize;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const firstPass = @import("first_pass.zig").firstPass;
const secondPass = @import("second_pass.zig").secondPass;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const generateZig = @import("codegen_zig.zig").generateZig;

comptime {
    _ = @import("builtins.zig").builtins; // ?
}

pub const Script = struct {
    first_pass_result: FirstPassResult,
    code_gen_results: []const CodeGenResult,
};

pub fn loadScript(filename: []const u8, allocator: *std.mem.Allocator) !Script {
    const contents = try std.io.readFileAlloc(allocator, filename);

    const source: Source = .{
        .filename = filename,
        .contents = contents,
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
        .first_pass_result = result,
        .code_gen_results = code_gen_results,
    };
}

pub fn main() u8 {
    const allocator = std.heap.page_allocator;
    const script = loadScript("script.txt", allocator) catch |err| {
        std.debug.warn("{}\n", .{err});
        return 1;
    };
    // TODO defer script deinit
    generateZig(script.first_pass_result, script.code_gen_results) catch |err| {
        std.debug.warn("{}\n", .{err});
        return 1;
    };
    return 0;
}
