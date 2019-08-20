const Span = @import("basics.zig").Span;

// TODO - make this configurable. maybe just a few stock options (linear,
// square, cube?)
fn powerFunc(v: f32) f32 {
    const iv = 1.0 - v;
    return 1.0 - iv * iv * iv;
}

pub const Envelope = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        sample_rate: f32,
        attack_duration: f32,
        decay_duration: f32,
        sustain_volume: f32,
        release_duration: f32,
        note_on: bool,
    };

    const State = enum {
        Idle,
        Attack,
        Decay,
        Sustain,
    };

    t: f32,
    last_value: f32,
    start: f32,
    goal: f32,
    duration: f32,
    state: State,

    pub fn init() Envelope {
        return Envelope {
            .t = 0.0,
            .last_value = 0.0,
            .start = 0.0,
            .goal = 0.0,
            .duration = 0.0,
            .state = .Idle,
        };
    }

    fn changeState(self: *Envelope, new_state: State, goal: f32, duration: f32) void {
        self.state = new_state;
        self.start = self.last_value;
        self.goal = goal;
        self.t = 0.0;
        self.duration = duration;
    }

    fn paintTowardGoal(self: *Envelope, buf: []f32, i_ptr: *usize, params: Params) bool {
        var i = i_ptr.*; defer i_ptr.* = i;

        const t_step = 1.0 / (self.duration * params.sample_rate);
        var finished = false;

        while (!finished and i < buf.len) : (i += 1) {
            self.t += t_step;
            if (self.t >= 1.0) {
                self.t = 1.0;
                finished = true;
            }
            buf[i] += self.start + powerFunc(self.t) * (self.goal - self.start);
        }

        self.last_value = self.start + powerFunc(self.t) * (self.goal - self.start);

        return finished;
    }

    fn paintOn(self: *Envelope, buf: []f32, params: Params, new_note: bool) void {
        var i: usize = 0;

        if (self.state == .Idle or new_note) {
            self.changeState(.Attack, 1.0, params.attack_duration);
        }

        if (self.state == .Attack) {
            if (self.paintTowardGoal(buf, &i, params)) {
                if (params.sustain_volume < 1.0) {
                    self.changeState(.Decay, params.sustain_volume, params.decay_duration);
                } else {
                    self.changeState(.Sustain, 1.0, 0.0);
                }
            }

            if (i == buf.len) {
                return;
            }
        }

        if (self.state == .Decay) {
            if (self.paintTowardGoal(buf, &i, params)) {
                self.changeState(.Sustain, 1.0, 0.0);
            }

            if (i == buf.len) {
                return;
            }
        }

        if (self.state == .Sustain) {
            while (i < buf.len) : (i += 1) {
                buf[i] += self.last_value;
            }
        }
    }

    fn paintOff(self: *Envelope, buf: []f32, params: Params) void {
        if (self.state != .Idle) {
            self.changeState(.Idle, 0.0, params.release_duration);
        }

        if (self.t < 1.0) {
            var i: usize = 0;
            _ = self.paintTowardGoal(buf, &i, params);
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
