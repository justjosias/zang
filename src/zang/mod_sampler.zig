const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;

fn getSample(data: []const u8, index: usize) f32 {
    if (index < data.len / 2) {
        const b0 = data[index * 2 + 0];
        const b1 = data[index * 2 + 1];

        const uval = u16(b0) | (u16(b1) << 8);
        const sval = @bitCast(i16, uval);

        return @intToFloat(f32, sval) / 32768.0;
    } else {
        return 0.0;
    }
}

pub const Sampler = struct {
    pub const NumTempBufs = 0;

    sample_data: []const u8,
    sample_rate: f32,
    // `sample_freq`: if null, ignore note frequencies and always play at
    // original speed
    sample_freq: ?f32,

    t: f32,

    pub fn init(sample_data: []const u8, sample_rate: f32, sample_freq: ?f32) Sampler {
        return Sampler{
            .sample_data = sample_data,
            .sample_rate = sample_rate,
            .sample_freq = sample_freq,
            .t = 0.0,
        };
    }

    pub fn reset(self: *Sampler) void {
        self.t = 0.0;
    }

    // TODO - support looping

    pub fn paint(self: *Sampler, sample_rate: f32, out: []f32, note_on: bool, freq: f32, tmp: [0][]f32) void {
        const ratio = blk: {
            const note_ratio =
                if (self.sample_freq) |sample_freq|
                    freq / sample_freq
                else
                    1.0;

            break :blk self.sample_rate / sample_rate * note_ratio;
        };

        // FIXME - pulled these epsilon values out of my ass
        if (ratio > 0.9999 and ratio < 1.0001) {
            // no resampling needed
            const num_samples = self.sample_data.len / 2;
            var t = @floatToInt(usize, std.math.round(self.t));
            var i: usize = 0;

            if (t < num_samples) {
                const samples_remaining = num_samples - t;
                const samples_to_render = std.math.min(out.len, samples_remaining);

                while (i < samples_to_render) : (i += 1) {
                    out[i] += getSample(self.sample_data, t + i);
                }
            }

            self.t += @intToFloat(f32, out.len);
        } else {
            // resample (TODO - use a better filter)
            var i: usize = 0;

            while (i < out.len) : (i += 1) {
                const t0 = @floatToInt(usize, std.math.floor(self.t));
                const t1 = t0 + 1;
                const tfrac = @intToFloat(f32, t1) - self.t;

                const s0 = getSample(self.sample_data, t0);
                const s1 = getSample(self.sample_data, t1);

                const s = s0 * (1.0 - tfrac) + s1 * tfrac;

                out[i] += s;

                self.t += ratio;
            }
        }
    }
};
