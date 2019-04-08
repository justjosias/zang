const std = @import("std");

pub const AudioFormat = enum {
    S8,
    S16LSB,
};

pub fn mixDown(dst: []u8, mix_buffer: []const f32, audio_format: AudioFormat) void {
    switch (audio_format) {
        AudioFormat.S8 => {
            mixDownS8(dst, mix_buffer);
        },
        AudioFormat.S16LSB => {
            mixDownS16LSB(dst, mix_buffer);
        },
    }
}

// convert from float to 16-bit, applying clamping
fn mixDownS16LSB(dst: []u8, mix_buffer: []const f32) void {
    std.debug.assert(dst.len == mix_buffer.len * 2);

    var i: usize = 0; while (i < mix_buffer.len) : (i += 1) {
        const value = mix_buffer[i] * 8192.0; // 1.0 will end up at 25% volume

        const clamped_value =
            if (value <= -32767.0)
                i16(-32767)
            else if (value >= 32766.0)
                i16(32766)
            else
                @floatToInt(i16, value);

        dst[i * 2 + 0] = @intCast(u8, clamped_value & 0xFF);
        dst[i * 2 + 1] = @intCast(u8, (clamped_value >> 8) & 0xFF);
    }
}

fn mixDownS8(dst: []u8, mix_buffer: []const f32) void {
    std.debug.assert(dst.len == mix_buffer.len);

    var i: usize = 0; while (i < mix_buffer.len) : (i += 1) {
        const value = mix_buffer[i] * 64.0; // 1.0 will end up at 25% volume

        const clamped_value =
            if (value <= -127.0)
                i8(-127)
            else if (value >= 126.0)
                i8(126)
            else
                @floatToInt(i8, value);

        dst[i] = @bitCast(u8, clamped_value);
    }
}
