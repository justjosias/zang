const std = @import("std");
const WavContents = @import("read_wav.zig").WavContents;
const Span = @import("basics.zig").Span;

// FIXME - no effort at all has been made to optimize the sampler module
// FIXME - hardcoded to support only 16-bit wav files
// FIXME - use a better resampling filter
// TODO - support playing backward (as it is it will probably crash)
// TODO - more complex looping schemes

fn getSample(data: []const u8, index1: usize, loop: bool) f32 {
    const index = if (loop) index1 % (data.len / 2) else index1;

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
    pub const NumOutputs = 1;
    pub const NumTemps = 0;
    pub const Params = struct {
        sample_rate: f32,
        wav: WavContents,
        loop: bool,
    };

    t: f32,

    pub fn init() Sampler {
        return Sampler {
            .t = 0.0,
        };
    }

    pub fn paint(self: *Sampler, span: Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, note_id_changed: bool, params: Params) void {
        if (note_id_changed) {
            self.t = 0.0;
        }

        const out = outputs[0][span.start..span.end];

        const ratio = @intToFloat(f32, params.wav.sample_rate) / params.sample_rate;

        // FIXME - pulled these epsilon values out of my ass
        if (ratio > 0.9999 and ratio < 1.0001) {
            // no resampling needed
            const t = @floatToInt(usize, std.math.round(self.t));

            var i: usize = 0; while (i < out.len) : (i += 1) {
                out[i] += getSample(params.wav.data, t + i, params.loop);
            }

            self.t += @intToFloat(f32, out.len);
        } else {
            // resample
            var i: usize = 0; while (i < out.len) : (i += 1) {
                const t0 = @floatToInt(usize, std.math.floor(self.t));
                const t1 = t0 + 1;
                const tfrac = @intToFloat(f32, t1) - self.t;

                const s0 = getSample(params.wav.data, t0, params.loop);
                const s1 = getSample(params.wav.data, t1, params.loop);

                const s = s0 * (1.0 - tfrac) + s1 * tfrac;

                out[i] += s;

                self.t += ratio;
            }
        }

        if (self.t >= @intToFloat(f32, params.wav.data.len) and params.loop) {
            self.t -= @intToFloat(f32, params.wav.data.len);
        }
    }
};
