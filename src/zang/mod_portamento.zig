const std = @import("std");
const paintLineTowards = @import("paint_line.zig").paintLineTowards;

pub const Portamento = struct {
    pub const NumOutputs = 1;
    pub const NumInputs = 0;
    pub const NumTemps = 0;
    pub const Params = struct {
        velocity: f32,
        value: f32,
        note_on: bool,
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

    pub fn reset(self: *Portamento) void {}

    pub fn paintSpan(self: *Portamento, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const buf = outputs[0];

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
            std.mem.set(f32, buf, self.goal);
        } else {
            var i: u31 = 0;

            if (paintLineTowards(&self.value, sample_rate, buf, &i, 1.0 / params.velocity, self.goal)) {
                // reached the goal
                std.mem.set(f32, buf[i..], self.goal);
            }
        }
    }
};
