// implementation ripped from farbrausch's v2 (public domain)
// https://github.com/farbrausch/fr_public/blob/master/v2/LICENSE.txt
// https://github.com/farbrausch/fr_public/blob/master/v2/synth_core.cpp

const std = @import("std");

const fc32bit: f32 = 2147483648.0;

fn bits2float(u: u32) f32 {
    return @bitCast(f32, u);
}

// 32-bit value into float with 23 bits precision
fn utof23(x: u32) f32 {
    const f = bits2float((x >> 9) | 0x3f800000); // 1 + x/(2^32)
    return f - 1.0;
}

// float from [0,1) into 0.32 unsigned fixed-point
// this loses a bit, but that's what V2 does.
fn ftou32(v: f32) u32 {
    return u32(2) * @floatToInt(u32, v * fc32bit); // FIXME this overflows when v is 1.0...
}

pub const PulseOsc = struct {
    pub const NumOutputs = 1;
    pub const NumInputs = 0;
    pub const NumTemps = 0;
    pub const Params = struct {
        freq: f32,
        colour: f32,
    };

    cnt: u32,

    pub fn init() PulseOsc {
        return PulseOsc {
            .cnt = 0,
        };
    }

    pub fn reset(self: *PulseOsc) void {}

    pub fn paintSpan(self: *PulseOsc, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const buf = outputs[0];
        var cnt = self.cnt;
        const SRfcobasefrq = (2.0 * fc32bit) / sample_rate;
        const freq = @floatToInt(u32, SRfcobasefrq * params.freq);
        const brpt = ftou32(params.colour);
        const gain = 1.0;
        const gdf = gain / utof23(freq);
        const col = utof23(brpt);
        const cc121 = gdf * 2.0 * (col - 1.0) + gain;
        const cc212 = gdf * 2.0 * col - gain;
        var state = if ((cnt -% freq) < brpt) u32(3) else u32(0);

        var i: usize = 0; while (i < buf.len) : (i += 1) {
            const p = utof23(cnt);
            state = ((state << 1) | (if (cnt < brpt) u32(1) else u32(0))) & 3;
            const transition_code = state | (if (cnt < freq) u32(4) else u32(0));
            cnt +%= freq;
            buf[i] += switch (transition_code) {
                0b011 => gain, // up
                0b000 => -gain, // down
                0b010 => gdf * 2.0 * (col - p) + gain, // up down
                0b101 => gdf * 2.0 * p - gain, // down up
                0b111 => cc121, // up down up
                0b100 => cc212, // down up down
                else => unreachable,
            };
        }

        self.cnt = cnt;
    }
};
