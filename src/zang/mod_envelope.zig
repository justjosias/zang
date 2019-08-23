const Span = @import("basics.zig").Span;

const Painter = struct {
    pub const CurveFunction = enum {
        Linear,
        Squared,
        Cubed,
    };

    t: f32,
    last_value: f32,
    start: f32,

    fn init() Painter {
        return Painter {
            .t = 0.0,
            .last_value = 0.0,
            .start = 0.0,
        };
    }

    fn reset(self: *Painter) void {
        self.start = self.last_value;
        self.t = 0.0;
    }

    fn paintToward(self: *Painter, buf: []f32, i_ptr: *usize, sample_rate: f32, curve: Envelope.Curve, goal: f32) bool {
        if (self.t >= 1.0) {
            return true;
        }

        var curve_func: CurveFunction = undefined;
        var duration: f32 = undefined;
        switch (curve) {
            .Instantaneous => {
                self.last_value = goal;
                return true;
            },
            .Linear  => |dur| { curve_func = .Linear;  duration = dur; },
            .Squared => |dur| { curve_func = .Squared; duration = dur; },
            .Cubed   => |dur| { curve_func = .Cubed;   duration = dur; },
        }

        var i = i_ptr.*;
        defer i_ptr.* = i;

        const t_step = 1.0 / (duration * sample_rate);
        var finished = false;

        // TODO - this can be optimized
        while (!finished and i < buf.len) : (i += 1) {
            self.t += t_step;
            if (self.t >= 1.0) {
                self.t = 1.0;
                finished = true;
            }
            const it = 1.0 - self.t;
            const tp = switch (curve_func) {
                .Linear => self.t,
                .Squared => 1.0 - it * it,
                .Cubed => 1.0 - it * it * it,
            };
            self.last_value = self.start + tp * (goal - self.start);
            buf[i] += self.last_value;
        }

        return finished;
    }
};

pub const Envelope = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        sample_rate: f32,
        attack: Curve,
        decay: Curve,
        release: Curve,
        sustain_volume: f32,
        note_on: bool,
    };

    pub const Curve = union(enum) {
        Instantaneous,
        Linear: f32, // duration (must be > 0)
        Squared: f32, // ditto
        Cubed: f32, // ditto
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
        self.painter.reset();
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
