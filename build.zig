const std = @import("std");
const Builder = std.build.Builder;
const builtin = @import("builtin");

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const windows = b.option(bool, "windows", "create windows build") orelse false;

    var t = b.addTest("test.zig");
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&t.step);

    example(b, mode, windows, "play", "example_play.zig");
    example(b, mode, windows, "song", "example_song.zig");
    example(b, mode, windows, "subsong", "example_subsong.zig");
    example(b, mode, windows, "stereo", "example_stereo.zig");
    example(b, mode, windows, "curve", "example_curve.zig");
    example(b, mode, windows, "detuned", "example_detuned.zig");
    example(b, mode, windows, "laser", "example_laser.zig");
    example(b, mode, windows, "portamento", "example_portamento.zig");
    example(b, mode, windows, "arpeggiator", "example_arpeggiator.zig");
    example(b, mode, windows, "sampler", "example_sampler.zig");
    example(b, mode, windows, "polyphony", "example_polyphony.zig");
    example(b, mode, windows, "delay", "example_delay.zig");
    example(b, mode, windows, "mouse", "example_mouse.zig");
    example(b, mode, windows, "two", "example_two.zig");

    {
        var exe = b.addExecutable("write_wav", "examples/write_wav.zig");
        exe.setBuildMode(mode);

        if (windows) {
            exe.setTarget(builtin.Arch.x86_64, builtin.Os.windows, builtin.Abi.gnu);
        }

        exe.addPackagePath("zang", "src/zang.zig");
        exe.addPackagePath("zang-12tet", "src/zang-12tet.zig");

        exe.setOutputDir("zig-cache");

        b.default_step.dependOn(&exe.step);

        b.installArtifact(exe);

        const play = b.step("write_wav", "Run example 'write_wav'");
        const run = exe.run();
        play.dependOn(&run.step);
    }
}

fn example(b: *Builder, mode: builtin.Mode, windows: bool, comptime name: []const u8, comptime source_file: []const u8) void {
    var exe = b.addExecutable(name, "examples/example.zig");
    exe.setBuildMode(mode);

    if (windows) {
        exe.setTarget(builtin.Arch.x86_64, builtin.Os.windows, builtin.Abi.gnu);
    }

    exe.addPackagePath("zang", "src/zang.zig");
    exe.addPackagePath("zang-12tet", "src/zang-12tet.zig");
    exe.addIncludeDir(".");
    exe.addCSourceFile("examples/draw.c", [_][]const u8 {});
    exe.addBuildOption([]const u8, "example", "\"" ++ source_file ++ "\"");

    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("c");

    exe.setOutputDir("zig-cache");

    b.default_step.dependOn(&exe.step);

    b.installArtifact(exe);

    const play = b.step(name, "Run example '" ++ name ++ "'");
    const run = exe.run();
    play.dependOn(&run.step);
}
