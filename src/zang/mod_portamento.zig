const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;
const paintLineTowards = @import("paint_line.zig").paintLineTowards;

// i might be able to replace this with a curve interpolation mode.
pub const Portamento = struct {
    pub const NumTempBufs = 0;

    velocity: f32,
    value: f32,
    goal: f32,
    gap: bool,

    pub fn init(velocity: f32) Portamento {
        return Portamento{
            .velocity = velocity,
            .value = 0.0,
            .goal = 0.0,
            .gap = true,
        };
    }

    pub fn reset(self: *Portamento) void {}

    pub fn paint(self: *Portamento, sample_rate: f32, buf: []f32, note_on: bool, freq: f32, tmp: [0][]f32) void {
        if (note_on) {
            if (self.gap) {
                // if this note comes after a gap, snap instantly to the goal frequency
                self.value = freq;
                self.gap = false;
            }
            self.goal = freq;
        } else {
            self.gap = true;
        }

        if (self.velocity <= 0.0) {
            self.value = self.goal;
            std.mem.set(f32, buf, self.goal);
        } else {
            var i: u31 = 0;

            if (paintLineTowards(&self.value, sample_rate, buf, &i, 1.0 / self.velocity, self.goal)) {
                // reached the goal
                std.mem.set(f32, buf[i..], self.goal);
            }
        }
    }
};
