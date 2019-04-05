const std = @import("std");

const sin = @import("mod_oscillator.zig").sin;
const tri = @import("mod_oscillator.zig").tri;

fn expectCloseTo(func: fn(f32)f32, arg: f32, expected: f32) void {
  const actual = func(arg);

  const delta = expected - actual;

  if (delta < -0.001 or delta > 0.001) {
    std.debug.panic("expected f({.5}) = {.5}, got {.5}", arg, expected, actual);
  }
}

test "sin" {
  expectCloseTo(sin, 0.000, 0.0);
  expectCloseTo(sin, 0.125, 0.70711);
  expectCloseTo(sin, 0.250, 1.0);
  expectCloseTo(sin, 0.375, 0.70711);
  expectCloseTo(sin, 0.500, 0.0);
  expectCloseTo(sin, 0.625, -0.70711);
  expectCloseTo(sin, 0.750, -1.0);
  expectCloseTo(sin, 0.875, -0.70711);
  expectCloseTo(sin, 1.000, 0.0);
}

test "tri" {
  expectCloseTo(tri, 0.000, 0.0);
  expectCloseTo(tri, 0.125, 0.5);
  expectCloseTo(tri, 0.250, 1.0);
  expectCloseTo(tri, 0.375, 0.5);
  expectCloseTo(tri, 0.500, 0.0);
  expectCloseTo(tri, 0.625, -0.5);
  expectCloseTo(tri, 0.750, -1.0);
  expectCloseTo(tri, 0.875, -0.5);
  expectCloseTo(tri, 1.000, 0.0);
}
