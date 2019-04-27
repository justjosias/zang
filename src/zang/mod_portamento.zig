const std = @import("std");
const Notes = @import("notes.zig").Notes;
const paintLineTowards = @import("paint_line.zig").paintLineTowards;

pub const Portamento = struct {
    pub const NumOutputs = 1;
    pub const NumInputs = 0;
    pub const NumTemps = 0;
    pub const Params = struct {
        value: f32,
        note_on: bool,
    };

    velocity: f32,
    value: f32,
    goal: f32,
    gap: bool,
    trigger: Notes(Params).Trigger(Portamento),

    pub fn init(velocity: f32) Portamento {
        return Portamento {
            .velocity = velocity,
            .value = 0.0,
            .goal = 0.0,
            .gap = true,
            .trigger = Notes(Params).Trigger(Portamento).init(),
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

    pub fn paint(self: *Portamento, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, impulses: ?*const Notes(Params).Impulse) void {
        self.trigger.paintFromImpulses(self, sample_rate, outputs, inputs, temps, impulses);
    }
};
