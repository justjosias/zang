const std = @import("std");
const zangscript = @import("zangscript");
const modules = @import("modules.zig");

const custom_builtin_package = zangscript.BuiltinPackage{
    .zig_package_name = "modules",
    .zig_import_path = "modules.zig",
    .builtins = &[_]zangscript.BuiltinModule{
        zangscript.getBuiltinModule(modules.FilteredSawtoothInstrument),
    },
    .enums = &[_]zangscript.BuiltinEnum{},
};

const builtin_packages = [_]zangscript.BuiltinPackage{
    zangscript.zang_builtin_package,
    custom_builtin_package,
};

pub fn main() u8 {
    var leak_count_allocator = std.testing.LeakCountAllocator.init(std.heap.page_allocator);
    defer leak_count_allocator.validate() catch {};

    var allocator = &leak_count_allocator.allocator;

    if (std.os.argv.len != 2) {
        std.debug.warn("requires 1 argument (script filename)\n", .{});
        return 1;
    }
    const filename = std.mem.spanZ(std.os.argv[1]);

    const contents = std.fs.cwd().readFileAlloc(allocator, filename, 16 * 1024 * 1024) catch |err| {
        std.debug.warn("failed to load {}: {}\n", .{ filename, err });
        return 1;
    };
    defer allocator.free(contents);

    const source: zangscript.Source = .{
        .filename = filename,
        .contents = contents,
    };

    var parse_result = zangscript.parse(source, &builtin_packages, allocator) catch |err| {
        if (err != error.Failed) std.debug.warn("parse failed: {}\n", .{err});
        return 1;
    };
    defer parse_result.deinit();

    var codegen_result = zangscript.codegen(source, parse_result, allocator) catch |err| {
        if (err != error.Failed) std.debug.warn("codegen failed: {}\n", .{err});
        return 1;
    };
    defer codegen_result.deinit();

    var stdout_file_out_stream = std.io.getStdOut().outStream();

    zangscript.generateZig(&stdout_file_out_stream, parse_result, codegen_result) catch |err| {
        std.debug.warn("generateZig failed: {}\n", .{err});
        return 1;
    };

    return 0;
}
