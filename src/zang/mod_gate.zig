const Span = @import("basics.zig").Span;
const addScalarInto = @import("basics.zig").addScalarInto;

// this is a simple version of the Envelope
pub const Gate = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        note_on: bool,
    };

    pub fn init() Gate {
        return .{};
    }

    pub fn paint(
        self: *Gate,
        span: Span,
        outputs: [num_outputs][]f32,
        temps: [num_temps][]f32,
        params: Params,
    ) void {
        if (params.note_on) {
            addScalarInto(span, outputs[0], 1.0);
        }
    }
};
