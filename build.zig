const std = @import("std");
const Builder = std.build.Builder;
const builtin = @import("builtin");

pub fn build(b: *Builder) void {
  const mode = b.standardReleaseOptions();
  const windows = b.option(bool, "windows", "create windows build") orelse false;

  var t = b.addTest("test.zig");
  t.linkSystemLibrary("c");
  const test_step = b.step("test", "Run all tests");
  test_step.dependOn(&t.step);

  example(b, mode, windows, "play", "example_play.zig");
  example(b, mode, windows, "song", "example_song.zig");
}

fn example(b: *Builder, mode: builtin.Mode, windows: bool, comptime name: []const u8, comptime source_file: []const u8) void {
  var exe = b.addExecutable(name, "example.zig");
  exe.setBuildMode(mode);

  if (windows) {
    exe.setTarget(builtin.Arch.x86_64, builtin.Os.windows, builtin.Abi.gnu);
  }

  // exe.addPackagePath("harold", "src/harold.zig"); // this doesn't work
  exe.addPackagePath("example", source_file);

  exe.linkSystemLibrary("SDL2");
  exe.linkSystemLibrary("c");

  exe.setOutputDir("zig-cache");

  b.default_step.dependOn(&exe.step);

  b.installArtifact(exe);

  const play = b.step(name, "Run example '" ++ name ++ "'");
  const run = exe.run();
  play.dependOn(&run.step);
}
