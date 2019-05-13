const std = @import("std");
const paintLineTowards = @import("paint_line.zig").paintLineTowards;

pub const Envelope = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 0;
    pub const Params = struct {
        sample_rate: f32,
        // durations: these are how long it would take to go from zero.
        // it will actually be shorter if pm.envelope is already starting
        // somewhere (from a previous note)
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

    envelope: f32,
    state: State,

    pub fn init() Envelope {
        return Envelope {
            .envelope = 0.0,
            .state = .Idle,
        };
    }

    pub fn reset(self: *Envelope) void {
        self.state = .Idle;
    }

    fn paintOn(self: *Envelope, buf: []f32, params: Params) void {
        const buf_len = @intCast(u31, buf.len);
        var i: u31 = 0;

        if (self.state == .Idle) {
            self.state = .Attack;
        }

        if (self.state == .Attack) {
            const goal = 1.0;

            if (self.envelope >= goal) {
                self.state = .Decay;
            } else {
                if (paintLineTowards(&self.envelope, params.sample_rate, buf, &i, params.attack_duration, goal)) {
                    self.state = .Decay;
                }
            }

            if (i == buf_len) {
                return;
            }
        }

        if (self.state == .Decay) {
            const goal = params.sustain_volume;

            if (paintLineTowards(&self.envelope, params.sample_rate, buf, &i, params.decay_duration, goal)) {
                self.state = .Sustain;
            }

            if (i == buf_len) {
                return;
            }
        }

        if (self.state == .Sustain) {
            while (i < buf_len) : (i += 1) {
                buf[i] += self.envelope;
            }
        }
    }

    fn paintOff(self: *Envelope, buf: []f32, params: Params) void {
        self.state = .Idle;

        if (self.envelope > 0.0) {
            var i: u31 = 0;

            _ = paintLineTowards(&self.envelope, params.sample_rate, buf, &i, params.release_duration, 0.0);
        }
    }

    pub fn paint(self: *Envelope, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        if (params.note_on) {
            self.paintOn(outputs[0], params);
        } else {
            self.paintOff(outputs[0], params);
        }
    }
};
