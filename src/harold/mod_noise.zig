const std = @import("std");

pub const Noise = struct {
    r: std.rand.Xoroshiro128,

    pub fn init() Noise {
        return Noise{
            .r = std.rand.DefaultPrng.init(0),
        };
    }

    pub fn paint(self: *Noise, buf: []f32) void {
        var r = self.r;
        var i: usize = 0;

        while (i < buf.len) : (i += 1) {
            buf[i] = r.random.float(f32) * 2.0 - 1.0;
        }
    }
};
