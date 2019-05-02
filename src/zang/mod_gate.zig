const basics = @import("basics.zig");

// this is a simple version of the Envelope
pub const Gate = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 0;
    pub const Params = struct {
        note_on: bool,
    };

    pub fn init() Gate {
        return Gate {};
    }

    pub fn reset(self: *Gate) void {}

    pub fn paint(self: *Gate, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        if (params.note_on) {
            basics.addScalarInto(outputs[0], 1.0);
        }
    }
};
