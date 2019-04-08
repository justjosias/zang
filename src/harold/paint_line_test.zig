const std = @import("std");

const paintLine = @import("paint_line.zig").paintLine;

fn expectCloseTo(actual: f32, expected: f32) void {
    const delta = expected - actual;

    if (delta < -0.001 or delta > 0.001) {
        std.debug.panic("expected {.5}, got {.5}", expected, actual);
    }
}

fn expectSliceCloseTo(comptime len: comptime_int, actual: [len]f32, expected: [len]f32) void {
    var i: usize = 0;
    var all_ok = true;
    var index_ok: [len]bool = undefined;
    while (i < len) : (i += 1) {
        const delta = expected[i] - actual[i];
        const ok = delta >= -0.001 and delta <= 0.001;
        index_ok[i] = ok;
        if (!ok) {
            all_ok = false;
        }
    }
    if (!all_ok) {
        std.debug.warn("\n");
        i = 0; while (i < len) : (i += 1) {
            if (index_ok[i]) {
                std.debug.warn("  [{}] {.5} ok\n", i, actual[i]);
            } else {
                std.debug.warn("  [{}] {.5}, expected {.5}\n", i, actual[i], expected[i]);
            }
        }
        std.debug.panic("expectSliceCloseTo failure");
    }
}

var buf4: [4]f32 = undefined;
var buf8: [8]f32 = undefined;
var last: f32 = undefined;

test "paintLine: buf.len=4, full_length=4, 0 to 1, buf starts at all 10's" {
    // test that the function adds to the existing buffer values
    std.mem.set(f32, buf4[0..], 10.0);
    last = paintLine(buf4[0..], 4, 0.0, 1.0);
    expectCloseTo(last, 1.0);
    expectSliceCloseTo(4, buf4, [4]f32{10.25, 10.5, 10.75, 11.0});
}

test "paintLine: buf.len=8, full_length=8, 0 to 1" {
    std.mem.set(f32, buf8[0..], 0.0);
    last = paintLine(buf8[0..], 8, 0.0, 1.0);
    expectCloseTo(last, 1.0);
    expectSliceCloseTo(8, buf8, [8]f32{0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0});
}

// line cut in half, test 1/2
test "paintLine: buf.len=4, full_length=8, 0 to 1" {
    std.mem.set(f32, buf4[0..], 0.0);
    last = paintLine(buf4[0..], 8, 0.0, 1.0);
    expectCloseTo(last, 0.5);
    expectSliceCloseTo(4, buf4, [4]f32{0.125, 0.25, 0.375, 0.5});
}

// line cut in half, test 2/2 (completes the line that was started in the previous test)
// this proves that a line decomposed into multiple buffers should have the
// same steady slope as the line drawn all at once
test "paintLine: buf.len=4, full_length=4, 0.5 to 1" {
    std.mem.set(f32, buf4[0..], 0.0);
    last = paintLine(buf4[0..], 4, 0.5, 1.0);
    expectCloseTo(last, 1.0);
    expectSliceCloseTo(4, buf4, [4]f32{0.625, 0.75, 0.875, 1.0});
}

test "paintLine: buf.len=4, full_length=4, 2 to -1" {
    std.mem.set(f32, buf4[0..], 0.0);
    last = paintLine(buf4[0..], 4, 2.0, -1.0);
    expectCloseTo(last, -1.0);
    expectSliceCloseTo(4, buf4, [4]f32{1.25, 0.5, -0.25, -1.0});
}

test "paintLine: buf.len=4, full_length=8, 2 to -1" {
    std.mem.set(f32, buf4[0..], 0.0);
    last = paintLine(buf4[0..], 8, 2.0, -1.0);
    expectCloseTo(last, 0.5);
    expectSliceCloseTo(4, buf4, [4]f32{1.625, 1.25, 0.875, 0.5});
}
