const basics = @import("basics.zig");

// this is a simple version of the Envelope
pub const Gate = struct {
    pub const NumTempBufs = 0;

    pub fn init() Gate {
        return Gate {};
    }

    pub fn reset(self: *Gate) void {
    }

    pub fn paint(self: *Gate, sample_rate: f32, out: []f32, note_on: bool, freq: f32, tmp: [0][]f32) void {
        if (note_on) {
            basics.addScalarInto(out, 1.0);
        }
    }
};
