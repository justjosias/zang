const std = @import("std");
const basics = @import("basics.zig");

pub const Decimator = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 0;
    pub const Params = struct {
        input: []const f32,
        fake_sample_rate: f32,
    };

    dval: f32,
    dcount: f32,

    pub fn init() Decimator {
        return Decimator {
            .dval = 0.0,
            .dcount = 1.0,
        };
    }

    pub fn reset(self: *Decimator) void {
        self.dval = 0.0;
        self.dcount = 1.0;
    }

    pub fn paint(self: *Decimator, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const output = outputs[0];

        if (params.fake_sample_rate >= sample_rate) {
            basics.addInto(output, params.input);

            self.dval = 0.0;
            self.dcount = 0;
        } else if (params.fake_sample_rate > 0.0) {
            const ratio = params.fake_sample_rate / sample_rate;
            var dcount = self.dcount;
            var dval = self.dval;

            var i: usize = 0; while (i < output.len) : (i += 1) {
                dcount += ratio;
                if (dcount >= 1.0) {
                    dval = params.input[i];
                    dcount -= 1.0;
                }
                output[i] += dval;
            }

            self.dcount = dcount;
            self.dval = dval;
        }
    }
};