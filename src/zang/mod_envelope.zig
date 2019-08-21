const Span = @import("basics.zig").Span;

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

    pub const CurveType = enum {
        Linear,
        Squared,
        Cubed,
    };

    pub const Curve = struct {
        curve_type: CurveType,
        duration: f32,
    };

    const State = enum {
        Initial,
        Attack,
        Decay,
        Sustain,
        Release,
    };

    t: f32,
    last_value: f32,
    start: f32,
    goal: f32,
    curve: ?Curve,
    state: State,

    pub fn init() Envelope {
        return Envelope {
            .t = 0.0,
            .last_value = 0.0,
            .start = 0.0,
            .goal = 0.0,
            .curve = null,
            .state = .Initial,
        };
    }

    fn changeState(self: *Envelope, new_state: State, goal: f32, curve: ?Curve) void {
        self.state = new_state;
        self.start = self.last_value;
        self.goal = goal;
        self.t = 0.0;
        self.curve = curve;
    }

    fn paintTowardGoal(self: *Envelope, buf: []f32, i_ptr: *usize, sample_rate: f32) bool {
        const curve = self.curve.?;

        var i = i_ptr.*;
        defer i_ptr.* = i;

        const t_step = 1.0 / (curve.duration * sample_rate);
        var finished = false;

        // TODO - this can be optimized
        while (!finished and i < buf.len) : (i += 1) {
            self.t += t_step;
            if (self.t >= 1.0) {
                self.t = 1.0;
                finished = true;
            }
            const it = 1.0 - self.t;
            const tp = switch (curve.curve_type) {
                .Linear => self.t,
                .Squared => 1.0 - it * it,
                .Cubed => 1.0 - it * it * it,
            };
            self.last_value = self.start + tp * (self.goal - self.start);
            buf[i] += self.last_value;
        }

        return finished;
    }

    fn paintOn(self: *Envelope, buf: []f32, params: Params, new_note: bool) void {
        var i: usize = 0;

        if (new_note) {
            self.changeState(.Attack, 1.0, params.attack);
        }

        if (self.state == .Attack) {
            if (self.paintTowardGoal(buf, &i, params.sample_rate)) {
                if (params.sustain_volume < 1.0) {
                    self.changeState(.Decay, params.sustain_volume, params.decay);
                } else {
                    self.changeState(.Sustain, 1.0, null);
                }
            }
        }

        if (self.state == .Decay) {
            if (self.paintTowardGoal(buf, &i, params.sample_rate)) {
                self.changeState(.Sustain, 1.0, null);
            }
        }

        if (self.state == .Sustain) {
            while (i < buf.len) : (i += 1) {
                buf[i] += self.last_value;
            }
        }
    }

    fn paintOff(self: *Envelope, buf: []f32, params: Params) void {
        if (self.state == .Initial) {
            return;
        }
        if (self.state != .Release) {
            self.changeState(.Release, 0.0, params.release);
        }

        if (self.t < 1.0) {
            var i: usize = 0;
            _ = self.paintTowardGoal(buf, &i, params.sample_rate);
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
