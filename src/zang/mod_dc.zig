const basics = @import("basics.zig");
const Notes = @import("notes.zig").Notes;

pub const DC = struct {
    pub const NumOutputs = 1;
    pub const NumInputs = 0;
    pub const NumTemps = 0;
    pub const Params = struct {
        value: f32,
    };

    trigger: Notes(Params).Trigger(DC),

    pub fn init() DC {
        return DC {
            .trigger = Notes(Params).Trigger(DC).init(),
        };
    }

    pub fn reset(self: *DC) void {}

    pub fn paintSpan(self: *DC, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, tmp: [NumTemps][]f32, params: Params) void {
        basics.addScalarInto(outputs[0], params.value);
    }

    pub fn paint(self: *DC, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, impulses: ?*const Notes(Params).Impulse) void {
        self.trigger.paintFromImpulses(self, sample_rate, outputs, inputs, temps, impulses);
    }
};
