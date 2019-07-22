const Span = @import("basics.zig").Span;
const addScalarInto = @import("basics.zig").addScalarInto;

pub const DC = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        value: f32,
    };

    pub fn init() DC {
        return DC {};
    }

    pub fn paint(self: *DC, span: Span, outputs: [num_outputs][]f32, tmp: [num_temps][]f32, params: Params) void {
        addScalarInto(span, outputs[0], params.value);
    }
};
