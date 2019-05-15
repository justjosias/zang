const Span = @import("basics.zig").Span;
const addScalarInto = @import("basics.zig").addScalarInto;

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

    pub fn paint(self: *Gate, span: Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        if (params.note_on) {
            addScalarInto(span, outputs[0], 1.0);
        }
    }
};
