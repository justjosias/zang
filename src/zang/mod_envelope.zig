const std = @import("std");
const Notes = @import("notes.zig").Notes;

const Impulse = @import("note_span.zig").Impulse;
const paintLineTowards = @import("paint_line.zig").paintLineTowards;

// durations: these are how long it would take to go from zero.
// it will actually be shorter if pm.envelope is already starting somewhere (from a previous note)
pub const EnvParams = struct {
    attack_duration: f32,
    decay_duration: f32,
    sustain_volume: f32,
    release_duration: f32,
};

pub const EnvState = enum {
    Idle,
    Attack,
    Decay,
    Sustain,
};

pub const Envelope = struct {
    pub const NumOutputs = 1;
    pub const NumInputs = 0;
    pub const NumTemps = 0;
    pub const Params = struct {
        note_on: bool,
    };

    params: EnvParams,
    envelope: f32,
    state: EnvState,
    trigger: Notes(Params).Trigger(Envelope),

    pub fn init(params: EnvParams) Envelope {
        return Envelope{
            .params = params,
            .envelope = 0.0,
            .state = .Idle,
            .trigger = Notes(Params).Trigger(Envelope).init(),
        };
    }

    pub fn reset(self: *Envelope) void {
        self.state = .Idle;
    }

    fn paintOn(self: *Envelope, sample_rate: f32, buf: []f32) void {
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
                if (paintLineTowards(&self.envelope, sample_rate, buf, &i, self.params.attack_duration, goal)) {
                    self.state = .Decay;
                }
            }

            if (i == buf_len) {
                return;
            }
        }

        if (self.state == .Decay) {
            const goal = self.params.sustain_volume;

            if (paintLineTowards(&self.envelope, sample_rate, buf, &i, self.params.decay_duration, goal)) {
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

    fn paintOff(self: *Envelope, sample_rate: f32, buf: []f32) void {
        self.state = .Idle;

        if (self.envelope > 0.0) {
            var i: u31 = 0;

            _ = paintLineTowards(&self.envelope, sample_rate, buf, &i, self.params.release_duration, 0.0);
        }
    }

    pub fn paintSpan(self: *Envelope, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        if (params.note_on) {
            self.paintOn(sample_rate, outputs[0]);
        } else {
            self.paintOff(sample_rate, outputs[0]);
        }
    }

    pub fn paint(self: *Envelope, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, impulses: ?*const Notes(Params).Impulse) void {
        self.trigger.paintFromImpulses(self, sample_rate, outputs, inputs, temps, impulses);
    }
};
