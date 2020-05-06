const std = @import("std");
const Span = @import("basics.zig").Span;

pub const Time = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        sample_rate: f32,
    };

    t: f32,

    pub fn init() Time {
        return .{
            .t = 0,
        };
    }

    pub fn paint(
        self: *Time,
        span: Span,
        outputs: [num_outputs][]f32,
        temps: [num_temps][]f32,
        note_id_changed: bool,
        params: Params,
    ) void {
        const step = 1.0 / params.sample_rate;
        var t = self.t;
        var i = span.start;
        while (i < span.end) : (i += 1) {
            outputs[0][i] += t;
            t += step;
        }
        self.t = t;
    }
};
