const std = @import("std");
const Span = @import("basics.zig").Span;

pub const Noise = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {};

    r: std.rand.Xoroshiro128,

    pub fn init(seed: u64) Noise {
        return Noise {
            .r = std.rand.DefaultPrng.init(seed),
        };
    }

    pub fn paint(self: *Noise, span: Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, params: Params) void {
        const buf = outputs[0][span.start..span.end];
        var r = self.r;
        var i: usize = 0;

        while (i < buf.len) : (i += 1) {
            buf[i] = r.random.float(f32) * 2.0 - 1.0;
        }

        self.r = r;
    }
};
