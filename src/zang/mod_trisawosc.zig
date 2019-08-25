// implementation ripped from farbrausch's v2 (public domain)
// https://github.com/farbrausch/fr_public/blob/master/v2/LICENSE.txt
// https://github.com/farbrausch/fr_public/blob/master/v2/synth_core.cpp

const Span = @import("basics.zig").Span;

const fc32bit = f32(1 << 32);

inline fn sqr(v: f32) f32 {
    return v * v;
}

inline fn clamp01(v: f32) f32 {
    return if (v < 0.0) 0.0 else if (v > 1.0) 1.0 else v;
}

// 32-bit value into float with 23 bits precision
inline fn utof23(x: u32) f32 {
    return @bitCast(f32, (x >> 9) | 0x3f800000) - 1;
}

// float from [0,1) into 0.32 unsigned fixed-point
inline fn ftou32(v: f32) u32 {
    return @floatToInt(u32, v * fc32bit * 0.99995);
}

pub const TriSawOsc = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        color: f32,
    };

    cnt: u32,

    pub fn init() TriSawOsc {
        return TriSawOsc { .cnt = 0 };
    }

    pub fn paint(self: *TriSawOsc, span: Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, params: Params) void {
        if (params.freq < 0 or params.freq > params.sample_rate / 8.0) {
            return;
        }
        // note: farbrausch code includes some explanatory comments. i've
        // preserved the variable names they used, but condensed the code
        const buf = outputs[0][span.start..span.end];
        var cnt = self.cnt;
        const SRfcobasefrq = fc32bit / params.sample_rate;
        const freq = @floatToInt(u32, SRfcobasefrq * params.freq);
        const brpt = ftou32(clamp01(params.color));
        const gain = 0.7;
        const f = utof23(freq);
        const omf = 1.0 - f;
        const rcpf = 1.0 / f;
        const col = utof23(brpt);
        const c1 = gain / col;
        const c2 = -gain / (1.0 - col);
        var state = if ((cnt -% freq) < brpt) u32(3) else u32(0);
        var i: usize = 0; while (i < buf.len) : (i += 1) {
            const p = utof23(cnt) - col;
            state = ((state << 1) | @boolToInt(cnt < brpt)) & 3;
            buf[i] += gain + switch (state | (u32(@boolToInt(cnt < freq)) << 2)) {
                0b011 => c1 * (p + p - f), // up
                0b000 => c2 * (p + p - f), // down
                0b010 => rcpf * (c2 * sqr(p) - c1 * sqr(p - f)), // up down
                0b101 => -rcpf * (gain + c2 * sqr(p + omf) - c1 * sqr(p)), // down up
                0b111 => -rcpf * (gain + c1 * omf * (p + p + omf)), // up down up
                0b100 => -rcpf * (gain + c2 * omf * (p + p + omf)), // down up down
                else => unreachable,
            };
            cnt +%= freq;
        }
        self.cnt = cnt;
    }
};
