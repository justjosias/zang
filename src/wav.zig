const std = @import("std");

pub const PreloadedInfo = struct {
    num_channels: usize,
    sample_rate: usize,
    bytes_per_sample: usize, // 1 (8-bit), 2 (16-bit), 3 (24-bit), or 4 (32-bit)
    num_samples: usize,

    pub fn getNumBytes(self: PreloadedInfo) usize {
        return self.num_samples * self.num_channels * self.bytes_per_sample;
    }
};

pub fn Loader(comptime ReadError: type) type {
    return struct {
        fn readIdentifier(stream: *std.io.InStream(ReadError)) ![4]u8 {
            var quad: [4]u8 = undefined;
            try stream.readNoEof(quad[0..]);
            return quad;
        }

        fn preloadError(verbose: bool, comptime message: []const u8) !PreloadedInfo {
            if (verbose) {
                std.debug.warn(message);
            }
            return error.WavLoadFailed;
        }

        pub fn preload(stream: *std.io.InStream(ReadError), verbose: bool) !PreloadedInfo {
            // read RIFF chunk descriptor (12 bytes)
            const chunk_id = try readIdentifier(stream);
            try stream.skipBytes(4); // ignore chunk_size
            const format = try readIdentifier(stream);
            if (!std.mem.eql(u8, chunk_id, "RIFF") or !std.mem.eql(u8, format, "WAVE")) {
                return preloadError(verbose, "missing \"RIFF\" or \"WAVE\" header\n");
            }

            // read "fmt" sub-chunk
            const subchunk1_id = try readIdentifier(stream);
            if (!std.mem.eql(u8, subchunk1_id, "fmt ")) {
                return preloadError(verbose, "missing \"fmt \" header\n");
            }
            const subchunk1_size = try stream.readIntLittle(u32);
            if (subchunk1_size != 16) {
                return preloadError(verbose, "not PCM (subchunk1_size != 16)\n");
            }
            const audio_format = try stream.readIntLittle(u16);
            if (audio_format != 1) {
                return preloadError(verbose, "not integer PCM (audio_format != 1)\n");
            }
            const num_channels = try stream.readIntLittle(u16);
            const sample_rate = try stream.readIntLittle(u32);
            const byte_rate = try stream.readIntLittle(u32);
            const block_align = try stream.readIntLittle(u16);
            const bits_per_sample = try stream.readIntLittle(u16);

            if (num_channels < 1 or num_channels > 16) {
                return preloadError(verbose, "invalid number of channels\n");
            }
            if (sample_rate < 1 or sample_rate > 192000) {
                return preloadError(verbose, "invalid sample_rate\n");
            }
            if (bits_per_sample < 8 or bits_per_sample > 32 or (bits_per_sample & 7) != 0) {
                return preloadError(verbose, "invalid number of bits per sample\n");
            }
            const bytes_per_sample = bits_per_sample >> 3;
            if (byte_rate != sample_rate * num_channels * bytes_per_sample) {
                return preloadError(verbose, "invalid byte_rate\n");
            }
            if (block_align != num_channels * bytes_per_sample) {
                return preloadError(verbose, "invalid block_align\n");
            }

            // read "data" sub-chunk header
            const subchunk2_id = try readIdentifier(stream);
            if (!std.mem.eql(u8, subchunk2_id, "data")) {
                return preloadError(verbose, "missing \"data\" header\n");
            }
            const subchunk2_size = try stream.readIntLittle(u32);
            if ((subchunk2_size % (num_channels * bytes_per_sample)) != 0) {
                return preloadError(verbose, "invalid subchunk2_size\n");
            }
            const num_samples = subchunk2_size / (num_channels * bytes_per_sample);

            return PreloadedInfo {
                .num_channels = num_channels,
                .sample_rate = sample_rate,
                .bytes_per_sample = bytes_per_sample,
                .num_samples = num_samples,
            };
        }

        pub fn load(stream: *std.io.InStream(ReadError), preloaded: PreloadedInfo, out_buffer: []u8) !void {
            const num_bytes = preloaded.getNumBytes();
            std.debug.assert(out_buffer.len >= num_bytes);
            try stream.readNoEof(out_buffer[num_bytes]);
        }
    };
}
