const std = @import("std");
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const Source = @import("common.zig").Source;
const tokenize = @import("tokenizer.zig").tokenize;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const firstPass = @import("first_pass.zig").firstPass;
const SecondPassResult = @import("second_pass.zig").SecondPassResult;
const secondPass = @import("second_pass.zig").secondPass;
const startCodegen = @import("codegen.zig").startCodegen;
const CodeGenResult = @import("codegen.zig").CodeGenResult;

pub const Script = struct {
    allocator: *std.mem.Allocator,
    contents: []const u8,
    first_pass_result: FirstPassResult,
    second_pass_result: SecondPassResult,
    codegen_result: CodeGenResult,

    pub fn deinit(self: *Script) void {
        self.allocator.free(self.contents);
        self.first_pass_result.deinit();
        self.second_pass_result.deinit();
        self.codegen_result.deinit();
    }
};

pub fn loadScript(filename: []const u8, builtin_packages: []const BuiltinPackage, allocator: *std.mem.Allocator) !Script {
    // FIXME should i make compilation not result in references to `contents`?
    // things like module names are currently just pointers into contents.
    // if i made them new allocs then i could free the contents sooner
    const contents = try std.fs.cwd().readFileAlloc(allocator, filename, 16*1024*1024);
    errdefer allocator.free(contents);

    const source: Source = .{
        .filename = filename,
        .contents = contents,
    };

    const tokens = try tokenize(source, allocator);
    defer allocator.free(tokens);

    var first_pass_result = try firstPass(source, tokens, builtin_packages, allocator);
    errdefer first_pass_result.deinit();

    var second_pass_result = try secondPass(source, tokens, first_pass_result, allocator);
    errdefer second_pass_result.deinit();

    const codegen_result = try startCodegen(source, first_pass_result, second_pass_result, allocator);
    errdefer codegen_result.deinit();

    return Script{
        .allocator = allocator,
        .contents = contents,
        .first_pass_result = first_pass_result,
        .second_pass_result = second_pass_result,
        .codegen_result = codegen_result,
    };
}
