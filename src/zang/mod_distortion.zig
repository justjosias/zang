// distortion implementation ripped from farbrausch's v2 (public domain)
// https://github.com/farbrausch/fr_public/blob/master/v2/LICENSE.txt
// https://github.com/farbrausch/fr_public/blob/master/v2/synth_core.cpp

const std = @import("std");
const Span = @import("basics.zig").Span;

pub const DistortionType = enum{
    Overdrive,
    Clip,
};

pub const Distortion = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 0;
    pub const Params = struct {
        input: []const f32,
        distortionType: DistortionType,
        ingain: f32, // 0 to 1. 0.25 is even, anything above is amplification
        outgain: f32, // 0 to 1
        offset: f32, // -1 to +1
    };

    pub fn init() Distortion {
        return Distortion {};
    }

    pub fn paint(self: *Distortion, span: Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const output = outputs[0];

        const gain1 = std.math.pow(f32, 2.0, params.ingain * 8.0 - 2.0);

        switch (params.distortionType) {
            .Overdrive => {
                const gain2 = params.outgain / std.math.atan(gain1);
                const offs = gain1 * params.offset;

                var i = span.start; while (i < span.end) : (i += 1) {
                    output[i] += gain2 * std.math.atan(params.input[i] * gain1 + offs);
                }
            },
            .Clip => {
                const gain2 = params.outgain;
                const offs = gain1 * params.offset;

                var i = span.start; while (i < span.end) : (i += 1) {
                    const a = params.input[i] * gain1 + offs;
                    const b = if (a < -1.0) -1.0 else if (a > 1.0) 1.0 else a;
                    output[i] += gain2 * b;
                }
            },
        }
    }
};
