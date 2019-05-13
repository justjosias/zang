const basics = @import("basics.zig");

pub const DC = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 0;
    pub const Params = struct {
        value: f32,
    };

    pub fn init() DC {
        return DC {};
    }

    pub fn reset(self: *DC) void {}

    pub fn paint(self: *DC, outputs: [NumOutputs][]f32, tmp: [NumTemps][]f32, params: Params) void {
        basics.addScalarInto(outputs[0], params.value);
    }
};
