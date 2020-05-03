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

    var script = zangscript.compile(filename, contents, &builtin_packages, allocator) catch |err| {
        if (err != error.Failed) std.debug.warn("{}\n", .{err});
        return 1;
    };
    defer script.deinit();

    var stdout_file_out_stream = std.io.getStdOut().outStream();

    zangscript.generateZig(&stdout_file_out_stream, &builtin_packages, script) catch |err| {
        std.debug.warn("generateZig failed: {}\n", .{err});
        return 1;
    };

    return 0;
}
