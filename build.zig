const std = @import("std");
const Builder = std.build.Builder;
const builtin = @import("builtin");

pub fn build(b: *Builder) void {
  const mode = b.standardReleaseOptions();
  const windows = b.option(bool, "windows", "create windows build") orelse false;

  {
    var t = b.addTest("test.zig");
    t.linkSystemLibrary("c");
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&t.step);
  }

  {
    var exe = b.addExecutable("play", "examples/play.zig");
    exe.setBuildMode(mode);

    if (windows) {
      exe.setTarget(builtin.Arch.x86_64, builtin.Os.windows, builtin.Abi.gnu);
    }

    exe.addPackagePath("harold", "src/harold.zig");

    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("c");

    exe.setOutputDir("zig-cache");

    b.default_step.dependOn(&exe.step);

    b.installArtifact(exe);

    const play = b.step("play", "Run example 'play'");
    const run = exe.run();
    play.dependOn(&run.step);
  }
}
