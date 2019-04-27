const basics = @import("basics.zig");
const Notes = @import("notes.zig").Notes;

// this is a simple version of the Envelope
pub const Gate = struct {
    pub const NumOutputs = 1;
    pub const NumInputs = 0;
    pub const NumTemps = 0;
    pub const Params = struct {
        note_on: bool,
    };

    trigger: Notes(Params).Trigger(Gate),

    pub fn init() Gate {
        return Gate {
            .trigger = Notes(Params).Trigger(Gate).init(),
        };
    }

    pub fn reset(self: *Gate) void {}

    pub fn paintSpan(self: *Gate, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        if (params.note_on) {
            basics.addScalarInto(outputs[0], 1.0);
        }
    }

    pub fn paint(self: *Gate, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, impulses: ?*const Notes(Params).Impulse) void {
        self.trigger.paintFromImpulses(self, sample_rate, outputs, inputs, temps, impulses);
    }
};
