const std = @import("std");
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const Source = @import("tokenize.zig").Source;
const tokenize = @import("tokenize.zig").tokenize;
const ParseResult = @import("parse.zig").ParseResult;
const parse = @import("parse.zig").parse;
const codegen = @import("codegen.zig").codegen;
const CodeGenResult = @import("codegen.zig").CodeGenResult;

pub const Script = struct {
    allocator: *std.mem.Allocator,
    contents: []const u8,
    parse_result: ParseResult,
    codegen_result: CodeGenResult,

    pub fn deinit(self: *Script) void {
        self.allocator.free(self.contents);
        self.parse_result.deinit();
        self.codegen_result.deinit();
    }
};

pub fn loadScript(filename: []const u8, builtin_packages: []const BuiltinPackage, allocator: *std.mem.Allocator) !Script {
    // FIXME should i make compilation not result in references to `contents`?
    // things like module names are currently just pointers into contents.
    // if i made them new allocs then i could free the contents sooner
    const contents = try std.fs.cwd().readFileAlloc(allocator, filename, 16 * 1024 * 1024);
    errdefer allocator.free(contents);

    const source: Source = .{
        .filename = filename,
        .contents = contents,
    };

    const tokens = try tokenize(source, allocator);
    defer allocator.free(tokens);

    var parse_result = try parse(source, tokens, builtin_packages, allocator);
    errdefer parse_result.deinit();

    const codegen_result = try codegen(source, parse_result, allocator);
    errdefer codegen_result.deinit();

    return Script{
        .allocator = allocator,
        .contents = contents,
        .parse_result = parse_result,
        .codegen_result = codegen_result,
    };
}
