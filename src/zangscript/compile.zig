const std = @import("std");
const Context = @import("tokenize.zig").Context;
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
    errors_out: std.io.StreamSource.OutStream,
    errors_color: bool,
) !CompiledScript {
    const context: Context = .{
        .source = .{
            .filename = filename,
            .contents = contents,
        },
        .errors_out = errors_out,
        .errors_color = errors_color,
    };

    var parse_result = try parse(context, builtin_packages, allocator);
    errdefer parse_result.deinit();

    var codegen_result = try codegen(context, builtin_packages, parse_result, allocator);
    errdefer codegen_result.deinit();

    return CompiledScript{
        .parse_arena = parse_result.arena,
        .codegen_arena = codegen_result.arena,
        .modules = parse_result.modules,
        .module_results = codegen_result.module_results,
    };
}
