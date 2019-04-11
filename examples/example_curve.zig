// in this example a little melody plays every time you hit a key

const std = @import("std");
const harold = @import("harold");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = harold.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

const second = @floatToInt(usize, @intToFloat(f32, AUDIO_SAMPLE_RATE));

const carrierCurve = []harold.CurveNode {
    harold.CurveNode{ .frame = 0 * second / 2, .freq = 440.0 },
    harold.CurveNode{ .frame = 1 * second / 2, .freq = 880.0 },
    harold.CurveNode{ .frame = 2 * second / 2, .freq = 110.0 },
    harold.CurveNode{ .frame = 3 * second / 2, .freq = 660.0 },
    harold.CurveNode{ .frame = 4 * second / 2, .freq = 330.0 },
    harold.CurveNode{ .frame = 6 * second / 2, .freq = 20.0 },
};

const modulatorCurve = []harold.CurveNode {
    harold.CurveNode{ .frame = 0 * second / 2, .freq = 110.0 },
    harold.CurveNode{ .frame = 3 * second / 2, .freq = 55.0 },
    harold.CurveNode{ .frame = 6 * second / 2, .freq = 220.0 },
};

const CurvePlayer = struct {
    curve: harold.Curve,
    carrier: harold.Oscillator,
    modulator: harold.Oscillator,
    sub_frame_index: usize,
    note_id: usize,
    freq: f32,

    fn init() CurvePlayer {
        return CurvePlayer{
            .curve = harold.Curve.init(.SmoothStep),
            .carrier = harold.Oscillator.init(.Sine),
            .modulator = harold.Oscillator.init(.Sine),
            .sub_frame_index = 0,
            .note_id = 0,
            .freq = 0.0,
        };
    }

    fn paint(self: *CurvePlayer, sample_rate: u32, out: []f32, tmp0: []f32, tmp1: []f32) void {
        const freq_mul = self.freq / 440.0;

        harold.zero(tmp0);
        self.curve.paintFromCurve(sample_rate, tmp0, modulatorCurve, self.sub_frame_index, freq_mul);
        harold.zero(tmp1);
        self.modulator.paintControlledFrequency(sample_rate, tmp1, tmp0);
        harold.zero(tmp0);
        // note it's almost always bad to reuse a module, but Curve happens to hold no state so it works here...
        self.curve.paintFromCurve(sample_rate, tmp0, carrierCurve, self.sub_frame_index, freq_mul);
        self.carrier.paintControlledPhaseAndFrequency(sample_rate, out, tmp1, tmp0);

        self.sub_frame_index += out.len;
    }

    fn paintFromImpulses(
        self: *CurvePlayer,
        sample_rate: u32,
        out: []f32,
        track: []const harold.Impulse,
        tmp0: []f32,
        tmp1: []f32,
        frame_index: usize,
    ) void {
        std.debug.assert(out.len == tmp0.len);
        std.debug.assert(out.len == tmp1.len);

        var start: usize = 0;

        while (start < out.len) {
            const note_span = harold.getNextNoteSpan(track, frame_index, start, out.len);

            std.debug.assert(note_span.start == start);
            std.debug.assert(note_span.end > start);
            std.debug.assert(note_span.end <= out.len);

            const buf_span = out[note_span.start .. note_span.end];
            const tmp0_span = tmp0[note_span.start .. note_span.end];
            const tmp1_span = tmp1[note_span.start .. note_span.end];

            if (note_span.note) |note| {
                if (note.id != self.note_id) {
                    std.debug.assert(note.id > self.note_id);

                    self.note_id = note.id;
                    self.freq = note.freq;
                    self.sub_frame_index = 0;
                }

                self.paint(sample_rate, buf_span, tmp0_span, tmp1_span);
            } else {
                // gap between notes. but keep playing (sampler currently ignores note
                // end events).

                // don't paint at all if note_freq is null. that means we haven't hit
                // the first note yet
                if (self.note_id > 0) {
                    self.paint(sample_rate, buf_span, tmp0_span, tmp1_span);
                }
            }

            start = note_span.end;
        }
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    frame_index: usize,

    iq: harold.ImpulseQueue,
    curve_player: CurvePlayer,

    pub fn init() MainModule {
        return MainModule{
            .frame_index = 0,
            .iq = harold.ImpulseQueue.init(),
            .curve_player = CurvePlayer.init(),
        };
    }

    pub fn paint(self: *MainModule) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];

        harold.zero(out);

        self.curve_player.paintFromImpulses(AUDIO_SAMPLE_RATE, out, self.iq.getImpulses(), tmp0, tmp1, self.frame_index);

        self.iq.flush(self.frame_index, out.len);

        self.frame_index += out.len;

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool) ?common.KeyEvent {
        const f = harold.note_frequencies;

        if (!down) {
            return null;
        }

        if (switch (key) {
            c.SDLK_a => f.C4,
            c.SDLK_w => f.Cs4,
            c.SDLK_s => f.D4,
            c.SDLK_e => f.Ds4,
            c.SDLK_d => f.E4,
            c.SDLK_f => f.F4,
            c.SDLK_t => f.Fs4,
            c.SDLK_g => f.G4,
            c.SDLK_y => f.Gs4,
            c.SDLK_h => f.A4,
            c.SDLK_u => f.As4,
            c.SDLK_j => f.B4,
            c.SDLK_k => f.C5,
            else => null,
        }) |freq| {
            return common.KeyEvent{
                .iq = &self.iq,
                .freq = freq,
            };
        }

        return null;
    }
};
