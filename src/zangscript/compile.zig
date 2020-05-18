const std = @import("std");
const Context = @import("context.zig").Context;
const Source = @import("context.zig").Source;
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

pub const CompileOptions = struct {
    builtin_packages: []const BuiltinPackage,
    source: Source,
    errors_out: std.io.StreamSource.OutStream,
    errors_color: bool,
    dump_parse_out: ?std.io.StreamSource.OutStream = null,
    dump_codegen_out: ?std.io.StreamSource.OutStream = null,
};

pub fn compile(allocator: *std.mem.Allocator, options: CompileOptions) !CompiledScript {
    const context: Context = .{
        .builtin_packages = options.builtin_packages,
        .source = options.source,
        .errors_out = options.errors_out,
        .errors_color = options.errors_color,
    };

    var parse_result = try parse(context, allocator, options.dump_parse_out);
    errdefer parse_result.deinit();

    var codegen_result = try codegen(context, parse_result, allocator, options.dump_codegen_out);
    errdefer codegen_result.deinit();

    return CompiledScript{
        .parse_arena = parse_result.arena,
        .codegen_arena = codegen_result.arena,
        .modules = parse_result.modules,
        .module_results = codegen_result.module_results,
    };
}
