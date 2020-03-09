const PaintState = @import("painter.zig").PaintState;
const Painter = @import("painter.zig").Painter;
const Span = @import("basics.zig").Span;
const addScalarInto = @import("basics.zig").addScalarInto;

pub const Portamento = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        sample_rate: f32,
        curve: Painter.Curve,
        goal: f32,
        note_on: bool,
        prev_note_on: bool,
    };

    painter: Painter,

    pub fn init() Portamento {
        return .{
            .painter = Painter.init(),
        };
    }

    pub fn paint(
        self: *Portamento,
        span: Span,
        outputs: [num_outputs][]f32,
        temps: [num_temps][]f32,
        note_id_changed: bool,
        params: Params,
    ) void {
        const output = outputs[0][span.start..span.end];

        const curve =
            if (params.note_on and params.prev_note_on)
                params.curve
            else
                .instantaneous;

        if (params.note_on and note_id_changed) {
            self.painter.newCurve();
        }

        var paint_state = PaintState.init(output, params.sample_rate);
        if (self.painter.paintToward(&paint_state, curve, params.goal)) {
            // reached goal before end of buffer. set all subsequent samples
            // to `goal`
            self.painter.paintFlat(&paint_state, params.goal);
        }
    }
};
