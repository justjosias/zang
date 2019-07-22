const std = @import("std");
const zang = @import("zang");

const example = @import("example_song.zig");

const TOTAL_TIME = 20 * example.AUDIO_SAMPLE_RATE;

const bytes_per_sample = switch (example.AUDIO_FORMAT) {
    .S8 => 1,
    .S16LSB => 2,
};

fn writeWav(comptime Error: type, stream: *std.io.OutStream(Error), data: []const u8) !void {
    const data_len = @intCast(u32, data.len);

    // location of "data" header
    const data_chunk_pos: u32 = 36;

    // length of file
    const file_length = data_chunk_pos + 8 + data_len;

    try stream.write("RIFF");
    try stream.writeIntLittle(u32, file_length - 8);
    try stream.write("WAVE");

    try stream.write("fmt ");
    try stream.writeIntLittle(u32, 16); // PCM
    try stream.writeIntLittle(u16, 1); // uncompressed
    try stream.writeIntLittle(u16, example.MainModule.num_outputs);
    try stream.writeIntLittle(u32, example.AUDIO_SAMPLE_RATE);
    try stream.writeIntLittle(u32, example.AUDIO_SAMPLE_RATE * example.MainModule.num_outputs * bytes_per_sample);
    try stream.writeIntLittle(u16, example.MainModule.num_outputs * bytes_per_sample);
    try stream.writeIntLittle(u16, bytes_per_sample * 8);

    try stream.write("data");
    try stream.writeIntLittle(u32, data_len);
    if (example.AUDIO_FORMAT == .S8) {
        // wav file stores 8-bit as unsigned
        for (data) |byte| {
            const signed_byte = @bitCast(i8, byte);
            const unsigned_byte = @intCast(u8, i16(signed_byte) + 128);
            try stream.writeByte(unsigned_byte);
        }
    } else {
        try stream.write(data);
    }
}

var g_outputs: [example.MainModule.num_outputs][example.AUDIO_BUFFER_SIZE]f32 = undefined;
var g_temps: [example.MainModule.num_temps][example.AUDIO_BUFFER_SIZE]f32 = undefined;

var g_big_buffer: [TOTAL_TIME * bytes_per_sample * example.MainModule.num_outputs]u8 = undefined;

pub fn main() !void {
    var main_module = example.MainModule.init();

    var start: usize = 0;

    while (start < TOTAL_TIME) {
        const len = min(usize, example.AUDIO_BUFFER_SIZE, TOTAL_TIME - start);

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

    const file = try std.fs.File.openWrite("out.wav");
    var fileOutStream = file.outStream();
    try writeWav(std.fs.File.OutStream.Error, &fileOutStream.stream, g_big_buffer[0..]);
    file.close();
}

fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}
