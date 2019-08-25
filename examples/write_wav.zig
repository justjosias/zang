const std = @import("std");
const zang = @import("zang");
const wav = @import("wav");

const example = @import("example_song.zig");

const TOTAL_TIME = 19 * example.AUDIO_SAMPLE_RATE;

const bytes_per_sample = switch (example.AUDIO_FORMAT) {
    .S8 => 1,
    .S16LSB => 2,
};

var g_outputs: [example.MainModule.num_outputs][example.AUDIO_BUFFER_SIZE]f32 = undefined;
var g_temps: [example.MainModule.num_temps][example.AUDIO_BUFFER_SIZE]f32 = undefined;

var g_big_buffer: [TOTAL_TIME * bytes_per_sample * example.MainModule.num_outputs]u8 = undefined;

pub fn main() !void {
    var main_module = example.MainModule.init();

    var start: usize = 0;

    while (start < TOTAL_TIME) {
        const len = std.math.min(example.AUDIO_BUFFER_SIZE, TOTAL_TIME - start);

        const span = zang.Span {
            .start = 0,
            .end = len,
        };

        var outputs: [example.MainModule.num_outputs][]f32 = undefined;
        var temps: [example.MainModule.num_temps][]f32 = undefined;
        var i: usize = undefined;
        i = 0; while (i < example.MainModule.num_outputs) : (i += 1) {
            outputs[i] = g_outputs[i][0..];
            zang.zero(span, outputs[i]);
        }
        i = 0; while (i < example.MainModule.num_temps) : (i += 1) {
            temps[i] = g_temps[i][0..];
        }
        main_module.paint(span, outputs, temps);

        i = 0; while (i < example.MainModule.num_outputs) : (i += 1) {
            const m = bytes_per_sample * example.MainModule.num_outputs;
            zang.mixDown(
                g_big_buffer[start * m .. (start + len) * m],
                outputs[i][span.start .. span.end],
                example.AUDIO_FORMAT,
                example.MainModule.num_outputs,
                i,
                0.25,
            );
        }

        start += len;
    }

    if (example.AUDIO_FORMAT == .S8) {
        // convert from signed to unsigned 8-bit
        for (g_big_buffer) |*byte| {
            const signed_byte = @bitCast(i8, byte.*);
            byte.* = @intCast(u8, i16(signed_byte) + 128);
        }
    }

    const file = try std.fs.File.openWrite("out.wav");
    defer file.close();
    var fos = file.outStream();
    const Saver = wav.Saver(std.fs.File.WriteError);
    try Saver.save(&fos.stream, wav.SaveInfo {
        .num_channels = example.MainModule.num_outputs,
        .sample_rate = example.AUDIO_SAMPLE_RATE,
        .format = switch (example.AUDIO_FORMAT) {
            .S8 => .U8,
            .S16LSB => .S16LSB,
        },
        .data = g_big_buffer[0..],
    });
}
