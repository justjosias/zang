const std = @import("std");

pub fn zero(dest: []f32) void {
  std.mem.set(f32, dest, 0.0);
}

pub fn copy(dest: []f32, src: []const f32) void {
  std.debug.assert(dest.len == a.len and dest.len == b.len);

  std.mem.copy(f32, dest, src);
}

pub fn add(dest: []f32, a: []const f32, b: []const f32) void {
  std.debug.assert(dest.len == a.len and dest.len == b.len);

  var i: usize = 0;

  while (i < dest.len) : (i += 1) {
    dest[i] += a[i] + b[i];
  }
}

pub fn addInto(dest: []f32, src: []const f32) void {
  std.debug.assert(dest.len == src.len);

  var i: usize = 0;

  while (i < dest.len) : (i += 1) {
    dest[i] += src[i];
  }
}

pub fn multiply(dest: []f32, a: []const f32, b: []const f32) void {
  std.debug.assert(dest.len == a.len and dest.len == b.len);

  var i: usize = 0;

  while (i < dest.len) : (i += 1) {
    dest[i] += a[i] * b[i];
  }
}

pub fn multiplyScalar(dest: []f32, a: []const f32, b: f32) void {
  std.debug.assert(dest.len == a.len);

  var i: usize = 0;

  while (i < dest.len) : (i += 1) {
    dest[i] += a[i] * b;
  }
}
