const std = @import("std");
const zang = @import("zang");
const BuiltinModule = @import("builtins.zig").BuiltinModule;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const zang_builtin_package = @import("builtins.zig").zang_builtin_package;
const Source = @import("common.zig").Source;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const tokenize = @import("tokenizer.zig").tokenize;
const ModuleParam = @import("first_pass.zig").ModuleParam;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const firstPass = @import("first_pass.zig").firstPass;
const secondPass = @import("second_pass.zig").secondPass;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const generateZig = @import("codegen_zig.zig").generateZig;

const Script = struct {
    contents: []const u8, // this must be freed
    first_pass_result: FirstPassResult,
    code_gen_results: []const CodeGenResult,
};

const custom_builtin_package = BuiltinPackage{
    .zig_package_name = "modules",
    .zig_import_path = "modules.zig",
    .builtins = &[_]BuiltinModule{
        // FIXME...
        .{
            .name = "FilteredSawtoothInstrument",
            .params = &[_]ModuleParam{
                .{ .name = "sample_rate", .zig_name = "sample_rate", .param_type = .constant },
                .{ .name = "freq", .zig_name = "freq", .param_type = .constant_or_buffer },
                .{ .name = "note_on", .zig_name = "note_on", .param_type = .boolean },
            },
            .num_temps = 3,
            .num_outputs = 1,
        },
    },
};

fn loadScript(filename: []const u8, allocator: *std.mem.Allocator) !Script {
    // FIXME should i make compilation not result in references to `contents`?
    // things like module names are currently just pointers into contents.
    // if i made them new allocs then i could free the contents sooner
    const contents = try std.fs.cwd().readFileAlloc(allocator, filename, 16*1024*1024);
    errdefer allocator.free(contents);

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

    const builtin_packages = [_]BuiltinPackage{
        zang_builtin_package,
        custom_builtin_package,
    };

    var result = try firstPass(source, tokens, &builtin_packages, allocator);
    defer {
        // FIXME deinit fields
        //result.module_defs.deinit();
    }

    const code_gen_results = try secondPass(source, tokens, result, allocator);

    return Script{
        .contents = contents,
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
    defer allocator.free(script.contents);
    // TODO defer script deinit
    generateZig(script.first_pass_result, script.code_gen_results) catch |err| {
        std.debug.warn("{}\n", .{err});
        return 1;
    };
    return 0;
}
