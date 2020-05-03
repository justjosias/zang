const std = @import("std");
const Source = @import("tokenize.zig").Source;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const Module = @import("parse.zig").Module;
const parse = @import("parse.zig").parse;
const CodeGenModuleResult = @import("codegen.zig").CodeGenModuleResult;
const codegen = @import("codegen.zig").codegen;

pub const CompiledScript = struct {
    parse_arena: std.heap.ArenaAllocator,
    codegen_arena: std.heap.ArenaAllocator,
    modules: []const Module,
    module_results: []const CodeGenModuleResult,

    pub fn deinit(self: *CompiledScript) void {
        self.codegen_arena.deinit();
        self.parse_arena.deinit();
    }
};

pub fn compile(
    filename: []const u8,
    contents: []const u8,
    comptime builtin_packages: []const BuiltinPackage,
    allocator: *std.mem.Allocator,
) !CompiledScript {
    const source: Source = .{
        .filename = filename,
        .contents = contents,
    };

    var parse_result = try parse(source, builtin_packages, allocator);
    errdefer parse_result.deinit();

    var codegen_result = try codegen(source, builtin_packages, parse_result, allocator);
    errdefer codegen_result.deinit();

    return CompiledScript{
        .parse_arena = parse_result.arena,
        .codegen_arena = codegen_result.arena,
        .modules = parse_result.modules,
        .module_results = codegen_result.module_results,
    };
}
