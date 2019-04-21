const std = @import("std");
const basics = @import("basics.zig");

// when notes and curves are merged this can probably be removed in favour
// of using the Curve module
pub const DC = struct {
    pub const NumTempBufs = 0;

    pub fn init() DC {
        return DC {};
    }

    pub fn reset(self: *DC) void {}

    pub fn paint(self: *DC, sample_rate: f32, out: []f32, note_on: bool, freq: f32, tmp: [0][]f32) void {
        basics.addScalarInto(out, freq);
    }
};
