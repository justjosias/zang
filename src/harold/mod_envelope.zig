const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;
const getNextNoteSpan = @import("note_span.zig").getNextNoteSpan;
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
    params: EnvParams,
    envelope: f32,
    state: EnvState,
    note_id: usize,

    pub fn init(params: EnvParams) Envelope {
        return Envelope{
            .params = params,
            .envelope = 0.0,
            .state = EnvState.Idle,
            .note_id = 0,
        };
    }

    pub fn paintOn(self: *Envelope, sample_rate: u32, buf: []f32) void {
        const buf_len = @intCast(u31, buf.len);
        var i: u31 = 0;

        // this function will only have been called if we know that the note is
        // active during this buffer (either it has already started, or it starts
        // during this buffer).

        // FURTHERMORE, if note starts during this frame, we'll have received only
        // the relevant slice of dest_buffer. in other words, note always starts at
        // beginning of dest_buffer!

        if (self.state == EnvState.Idle) {
            self.state = EnvState.Attack;
        }

        if (self.state == EnvState.Attack) {
            const goal = 1.0;

            if (self.envelope >= goal) {
                self.state = EnvState.Decay;
            } else {
                if (paintLineTowards(&self.envelope, sample_rate, buf, &i, self.params.attack_duration, goal)) {
                    self.state = EnvState.Decay;
                }
            }

            if (i == buf_len) {
                return;
            }
        }

        if (self.state == EnvState.Decay) {
            const goal = self.params.sustain_volume;

            if (paintLineTowards(&self.envelope, sample_rate, buf, &i, self.params.decay_duration, goal)) {
                self.state = EnvState.Sustain;
            }

            if (i == buf_len) {
                return;
            }
        }

        if (self.state == EnvState.Sustain) {
            while (i < buf_len) : (i += 1) {
                buf[i] += self.envelope;
            }
        }
    }

    pub fn paintOff(self: *Envelope, sample_rate: u32, buf: []f32) void {
        if (self.envelope > 0.0) {
            var i: u31 = 0;

            _ = paintLineTowards(&self.envelope, sample_rate, buf, &i, self.params.release_duration, 0.0);
        }
    }

    pub fn paintFromImpulses(
        self: *Envelope,
        sample_rate: u32,
        buf: []f32,
        impulses: []const Impulse,
        frame_index: usize,
    ) void {
        var start: usize = 0;

        while (start < buf.len) {
            const note_span = getNextNoteSpan(impulses, frame_index, start, buf.len);

            std.debug.assert(note_span.start == start);
            std.debug.assert(note_span.end > start);
            std.debug.assert(note_span.end <= buf.len);

            const buf_span = buf[note_span.start .. note_span.end];

            if (note_span.note) |note| {
                if (note.id != self.note_id) {
                    std.debug.assert(note.id > self.note_id);

                    self.note_id = note.id;
                    self.state = EnvState.Idle;
                }

                self.paintOn(sample_rate, buf_span);
            } else {
                self.note_id = 0;
                self.state = EnvState.Idle;

                self.paintOff(sample_rate, buf_span);
            }

            start = note_span.end;
        }
    }
};
