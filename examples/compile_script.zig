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
    const allocator = std.heap.page_allocator;
    const script = zangscript.loadScript("examples/script.txt", &builtin_packages, allocator) catch |err| {
        std.debug.warn("{}\n", .{err});
        return 1;
    };
    defer allocator.free(script.contents);
    // TODO defer script deinit
    zangscript.generateZig(script.first_pass_result, script.code_gen_results) catch |err| {
        std.debug.warn("{}\n", .{err});
        return 1;
    };
    return 0;
}
