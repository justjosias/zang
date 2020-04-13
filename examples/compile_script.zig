const std = @import("std");
const zangscript = @import("zangscript");
const modules = @import("modules.zig");

const custom_builtin_package = zangscript.BuiltinPackage{
    .zig_package_name = "modules",
    .zig_import_path = "modules.zig",
    .builtins = &[_]zangscript.BuiltinModule{
        zangscript.getBuiltinModule(modules.FilteredSawtoothInstrument),
    },
};

const builtin_packages = [_]zangscript.BuiltinPackage{
    zangscript.zang_builtin_package,
    custom_builtin_package,
};

pub fn main() u8 {
    var leak_count_allocator = std.testing.LeakCountAllocator.init(std.heap.page_allocator);
    defer leak_count_allocator.validate() catch {};

    var allocator = &leak_count_allocator.allocator;

    var script = zangscript.loadScript("examples/script.txt", &builtin_packages, allocator) catch |err| {
        std.debug.warn("loadScript failed: {}\n", .{err});
        return 1;
    };
    defer script.deinit();

    zangscript.generateZig(script.first_pass_result, script.codegen_result) catch |err| {
        std.debug.warn("generateZig failed: {}\n", .{err});
        return 1;
    };

    return 0;
}
