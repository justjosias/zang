const std = @import("std");

pub fn readWav(buf: []const u8, out_sample_rate: *u32) ![]const u8 {
    var sis = std.io.SliceInStream.init(buf);
    const stream = &sis.stream;

    var quad: [4]u8 = undefined;

    try stream.readNoEof(quad[0..]);
    if (!std.mem.eql(u8, quad, "RIFF")) {
        return error.InvalidFile;
    }

    const file_length_minus_8 = try stream.readIntLittle(u32);

    try stream.readNoEof(quad[0..]);
    if (!std.mem.eql(u8, quad, "WAVE")) {
        return error.InvalidFile;
    }

    try stream.readNoEof(quad[0..]);
    if (!std.mem.eql(u8, quad, "fmt ")) {
        return error.InvalidFile;
    }

    const a = try stream.readIntLittle(u32);
    if (a != 16) {
        std.debug.warn("expected 16, got {}\n", a);
        return error.InvalidFile;
    }

    const b = try stream.readIntLittle(u16);
    if (b != 1) {
        std.debug.warn("expected 1, got {}\n", b);
        return error.InvalidFile;
    }

    const num_channels = try stream.readIntLittle(u16);
    if (num_channels != 1) {
        std.debug.warn("num_channels must be 1, got {}\n", num_channels);
        return error.InvalidFile;
    }

    const frequency = try stream.readIntLittle(u32);
    const thing = try stream.readIntLittle(u32);
    const bytes_per_sample = thing / frequency / num_channels;
    if (thing != frequency * num_channels * bytes_per_sample) {
        return error.InvalidFile;
    }
    if (bytes_per_sample != 2) {
        std.debug.warn("bytes_per_sample must be 2, got {}\n", bytes_per_sample);
        return error.InvalidFile;
    }

    const thing2 = try stream.readIntLittle(u16);
    if (thing2 != num_channels * bytes_per_sample) {
        return error.InvalidFile;
    }

    const bits_per_sample = try stream.readIntLittle(u16);
    if (bits_per_sample != bytes_per_sample * 8) {
        return error.InvalidFile;
    }

    try stream.readNoEof(quad[0..]);
    if (!std.mem.eql(u8, quad, "data")) {
        return error.InvalidFile;
    }

    const data_len = try stream.readIntLittle(u32);

    // data is here.
    const data_index = 44;

    out_sample_rate.* = frequency;

    return buf[data_index .. data_index + data_len];
}
