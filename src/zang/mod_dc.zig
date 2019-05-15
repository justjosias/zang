const Span = @import("basics.zig").Span;
const addScalarInto = @import("basics.zig").addScalarInto;

pub const DC = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 0;
    pub const Params = struct {
        value: f32,
    };

    pub fn init() DC {
        return DC {};
    }

    pub fn paint(self: *DC, span: Span, outputs: [NumOutputs][]f32, tmp: [NumTemps][]f32, params: Params) void {
        addScalarInto(span, outputs[0], params.value);
    }
};
