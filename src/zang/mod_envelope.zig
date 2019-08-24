const Span = @import("basics.zig").Span;
const Painter = @import("paint_line.zig").Painter;

pub const Envelope = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        sample_rate: f32,
        attack: Painter.Curve,
        decay: Painter.Curve,
        release: Painter.Curve,
        sustain_volume: f32,
        note_on: bool,
    };

    const State = enum {
        Idle,
        Attack,
        Decay,
        Sustain,
        Release,
    };

    state: State,
    painter: Painter,

    pub fn init() Envelope {
        return Envelope {
            .state = .Idle,
            .painter = Painter.init(),
        };
    }

    fn changeState(self: *Envelope, new_state: State) void {
        self.state = new_state;
        self.painter.newCurve();
    }

    fn paintOn(self: *Envelope, buf: []f32, params: Params, new_note: bool) void {
        var i: usize = 0;

        if (new_note) {
            self.changeState(.Attack);
        }

        if (self.state == .Attack) {
            if (self.painter.paintToward(buf, &i, params.sample_rate, params.attack, 1.0)) {
                if (params.sustain_volume < 1.0) {
                    self.changeState(.Decay);
                } else {
                    self.changeState(.Sustain);
                }
            }
        }

        if (self.state == .Decay) {
            if (self.painter.paintToward(buf, &i, params.sample_rate, params.decay, params.sustain_volume)) {
                self.changeState(.Sustain);
            }
        }

        if (self.state == .Sustain) {
            while (i < buf.len) : (i += 1) {
                buf[i] += params.sustain_volume;
            }
        }
    }

    fn paintOff(self: *Envelope, buf: []f32, params: Params) void {
        if (self.state == .Idle) {
            return;
        }

        var i: usize = 0;

        if (self.state != .Release) {
            self.changeState(.Release);
        }

        if (self.painter.paintToward(buf, &i, params.sample_rate, params.release, 0.0)) {
            self.changeState(.Idle);
        }
    }

    pub fn paint(self: *Envelope, span: Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, note_id_changed: bool, params: Params) void {
        const output = outputs[0][span.start..span.end];

        if (params.note_on) {
            self.paintOn(output, params, note_id_changed);
        } else {
            self.paintOff(output, params);
        }
    }
};
