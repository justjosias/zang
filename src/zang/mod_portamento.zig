const std = @import("std");
const paintLineTowards = @import("paint_line.zig").paintLineTowards;
const Span = @import("basics.zig").Span;

pub const Portamento = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        sample_rate: f32,
        mode: Mode,
        velocity: f32, // this has different meanings depending on the mode
        value: f32,
        note_on: bool,
    };
    pub const Mode = enum {
        Linear,
        CatchUp, // does this method have an actual name?
    };

    value: f32,
    goal: f32,
    gap: bool,

    pub fn init() Portamento {
        return Portamento {
            .value = 0.0,
            .goal = 0.0,
            .gap = true,
        };
    }

    pub fn paint(self: *Portamento, span: Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, params: Params) void {
        const output = outputs[0][span.start..span.end];

        if (params.note_on) {
            if (self.gap) {
                // if this note comes after a gap, snap instantly to the goal value
                self.value = params.value;
                self.gap = false;
            }
            self.goal = params.value;
        } else {
            self.gap = true;
        }

        if (params.velocity <= 0.0) {
            self.value = self.goal;
            std.mem.set(f32, output, self.goal);
        } else {
            switch (params.mode) {
                .Linear => {
                    var i: u31 = 0;
                    if (paintLineTowards(&self.value, params.sample_rate, output, &i, 1.0 / params.velocity, self.goal)) {
                        // reached the goal
                        std.mem.set(f32, output[i..], self.goal);
                    }
                },
                .CatchUp => {
                    var i: usize = 0; while (i < output.len) : (i += 1) {
                        self.value += (self.goal - self.value) * (params.velocity / params.sample_rate);
                        output[i] = self.value;
                    }
                },
            }
        }
    }
};
