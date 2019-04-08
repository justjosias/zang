const std = @import("std");

// linear interpolation. v1 is where we want to end up after full_length.
// full_length may be past the end of the buffer
// returns the value of the last sample rendered (will be the same as v1 if
// buf.len == full_length)
pub fn paintLine(buf: []f32, full_length: u31, v0: f32, v1: f32) f32 {
    std.debug.assert(buf.len > 0);
    std.debug.assert(buf.len <= full_length);

    const t1 = @intToFloat(f32, buf.len) / @intToFloat(f32, full_length);

    const v1_actual = v0 + t1 * (v1 - v0);

    const inv_len = 1.0 / @intToFloat(f32, buf.len);
    var i: usize = 0;

    var v: f32 = v0;
    const step = (v1_actual - v0) * inv_len;

    while (i < buf.len - 1) {
        v += step; // the first sample has already stepped forward
        buf[i] += v;
        i += 1;
    }

    // set the last sample manually, so it is exactly the destination value
    buf[buf.len - 1] += v1_actual;

    return v1_actual;
}

// return true if goal was reached
pub fn paintLineTowards(value: *f32, sample_rate: u32, buf: []f32, i_ptr: *u31, dur: f32, goal: f32) bool {
    const buf_len = @intCast(u31, buf.len);

    // how long will it take to get there?
    const time = std.math.fabs(goal - value.*) * dur;

    const s_time_in_samples = @floatToInt(i32, time * @intToFloat(f32, sample_rate));

    if (s_time_in_samples <= 0) {
        value.* = goal;
        return true;
    } else {
        const time_in_samples = @intCast(u31, s_time_in_samples);
        const i = i_ptr.*;

        const end = std.math.min(i + time_in_samples, buf_len);

        value.* = paintLine(buf[i..end], time_in_samples, value.*, goal);

        i_ptr.* = end;

        return i + time_in_samples <= buf_len;
    }
}
