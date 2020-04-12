const std = @import("std");

const examples = [_][]const u8 {
    "play",
    "song",
    "subsong",
    "envelope",
    "stereo",
    "curve",
    "detuned",
    "laser",
    "portamento",
    "arpeggiator",
    "sampler",
    "polyphony",
    "polyphony2",
    "delay",
    "mouse",
    "two",
    "script",
};

pub fn build(b: *std.build.Builder) void {
    b.step("test", "Run all tests").dependOn(&b.addTest("test.zig").step);
    inline for (examples) |name| {
        b.step(name, "Run example '" ++ name ++ "'")
            .dependOn(&example(b, name).run().step);
    }
    b.step("write_wav", "Run example 'write_wav'")
        .dependOn(&writeWav(b).run().step);
    b.step("zangscript", "Run 'zangscript' example program")
        .dependOn(&zangscript(b).run().step);
}

fn example(
    b: *std.build.Builder,
    comptime name: []const u8,
) *std.build.LibExeObjStep {
    var o = b.addExecutable(name, "examples/example.zig");
    o.setBuildMode(b.standardReleaseOptions());
    o.setOutputDir("zig-cache");
    o.addPackagePath("wav", "examples/zig-wav/wav.zig");
    o.addPackagePath("zang", "src/zang.zig");
    o.addPackagePath("zang-12tet", "src/zang-12tet.zig");
    o.addIncludeDir(".");
    o.addCSourceFile("examples/draw.c", &[_][]const u8 {});
    o.addBuildOption([]const u8, "example", "\"example_" ++ name ++ ".zig\"");
    o.linkSystemLibrary("SDL2");
    o.linkSystemLibrary("c");
    return o;
}

fn writeWav(b: *std.build.Builder) *std.build.LibExeObjStep {
    var o = b.addExecutable("write_wav", "examples/write_wav.zig");
    o.setBuildMode(b.standardReleaseOptions());
    o.setOutputDir("zig-cache");
    o.addPackagePath("wav", "examples/zig-wav/wav.zig");
    o.addPackagePath("zang", "src/zang.zig");
    o.addPackagePath("zang-12tet", "src/zang-12tet.zig");
    return o;
}

fn zangscript(b: *std.build.Builder) *std.build.LibExeObjStep {
    var o = b.addExecutable("zangscript", "examples/compile_script.zig");
    o.setBuildMode(b.standardReleaseOptions());
    o.setOutputDir("zig-cache");
    o.addPackagePath("zang", "src/zang.zig");
    o.addPackagePath("zang-12tet", "src/zang-12tet.zig");
    o.addPackagePath("zangscript", "src/zangscript.zig");
    return o;
}
