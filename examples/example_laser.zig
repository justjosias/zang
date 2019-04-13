// in this example you can play a simple monophonic synth with the keyboard

const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

const second = @floatToInt(usize, @intToFloat(f32, AUDIO_SAMPLE_RATE));

const A = 1000.0;
const B = 200.0;
const C = 100.0;

const carrierCurve = []zang.CurveNode {
    zang.CurveNode{ .frame = 0 * second / 10, .value = A },
    zang.CurveNode{ .frame = 1 * second / 10, .value = B },
    zang.CurveNode{ .frame = 2 * second / 10, .value = C },
};

const modulatorCurve = []zang.CurveNode {
    zang.CurveNode{ .frame = 0 * second / 10, .value = A },
    zang.CurveNode{ .frame = 1 * second / 10, .value = B },
    zang.CurveNode{ .frame = 2 * second / 10, .value = C },
};

const volumeCurve = []zang.CurveNode {
    zang.CurveNode{ .frame = 0 * second / 10, .value = 0.0 },
    zang.CurveNode{ .frame = 1 * second / 250, .value = 1.0 },
    zang.CurveNode{ .frame = 2 * second / 10, .value = 0.0 },
};

const CurvePlayer = struct {
    carrier_mul: f32,
    modulator_mul: f32,
    modulator_rad: f32,
    curve: zang.Curve,
    carrier: zang.Oscillator,
    modulator: zang.Oscillator,
    sub_frame_index: usize,
    note_id: usize,
    freq: f32,

    fn init(carrier_mul: f32, modulator_mul: f32, modulator_rad: f32) CurvePlayer {
        return CurvePlayer{
            .carrier_mul = carrier_mul,
            .modulator_mul = modulator_mul,
            .modulator_rad = modulator_rad,
            .curve = zang.Curve.init(.SmoothStep),
            .carrier = zang.Oscillator.init(.Sine),
            .modulator = zang.Oscillator.init(.Sine),
            .sub_frame_index = 0,
            .note_id = 0,
            .freq = 0.0,
        };
    }

    fn paint(self: *CurvePlayer, sample_rate: u32, out: []f32, tmp0: []f32, tmp1: []f32, tmp2: []f32) void {
        const freq_mul = self.freq / 440.0;

        zang.zero(tmp0);
        self.curve.paintFromCurve(sample_rate, tmp0, modulatorCurve, self.sub_frame_index, freq_mul * self.modulator_mul);
        zang.zero(tmp1);
        self.modulator.paintControlledFrequency(sample_rate, tmp1, tmp0);
        zang.multiplyWithScalar(tmp1, self.modulator_rad);
        zang.zero(tmp0);
        self.curve.paintFromCurve(sample_rate, tmp0, carrierCurve, self.sub_frame_index, freq_mul * self.carrier_mul);
        zang.zero(tmp2);
        self.carrier.paintControlledPhaseAndFrequency(sample_rate, tmp2, tmp1, tmp0);
        zang.zero(tmp0);
        self.curve.paintFromCurve(sample_rate, tmp0, volumeCurve, self.sub_frame_index, null);
        zang.multiply(out, tmp0, tmp2);

        self.sub_frame_index += out.len;
    }

    fn paintFromImpulses(
        self: *CurvePlayer,
        sample_rate: u32,
        out: []f32,
        track: []const zang.Impulse,
        tmp0: []f32,
        tmp1: []f32,
        tmp2: []f32,
        frame_index: usize,
    ) void {
        std.debug.assert(out.len == tmp0.len);
        std.debug.assert(out.len == tmp1.len);

        var start: usize = 0;

        while (start < out.len) {
            const note_span = zang.getNextNoteSpan(track, frame_index, start, out.len);

            std.debug.assert(note_span.start == start);
            std.debug.assert(note_span.end > start);
            std.debug.assert(note_span.end <= out.len);

            const buf_span = out[note_span.start .. note_span.end];
            const tmp0_span = tmp0[note_span.start .. note_span.end];
            const tmp1_span = tmp1[note_span.start .. note_span.end];
            const tmp2_span = tmp2[note_span.start .. note_span.end];

            if (note_span.note) |note| {
                if (note.id != self.note_id) {
                    std.debug.assert(note.id > self.note_id);

                    self.note_id = note.id;
                    self.freq = note.freq;
                    self.sub_frame_index = 0;
                }

                self.paint(sample_rate, buf_span, tmp0_span, tmp1_span, tmp2_span);
            } else {
                // gap between notes. but keep playing (sampler currently ignores note
                // end events).

                // don't paint at all if note_freq is null. that means we haven't hit
                // the first note yet
                if (self.note_id > 0) {
                    self.paint(sample_rate, buf_span, tmp0_span, tmp1_span, tmp2_span);
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
    buf3: [AUDIO_BUFFER_SIZE]f32,
    buf4: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    frame_index: usize,

    iq: zang.ImpulseQueue,
    curve_player: CurvePlayer,

    r: std.rand.Xoroshiro128,

    pub fn init() MainModule {
        return MainModule{
            .frame_index = 0,
            .iq = zang.ImpulseQueue.init(),
            // .curve_player = CurvePlayer.init(4.0, 0.125, 1.0), // enemy laser
            // .curve_player = CurvePlayer.init(0.5, 0.125, 1.0), // pain sound?
            // .curve_player = CurvePlayer.init(1.0, 9.0, 1.0), // some web effect?
            .curve_player = CurvePlayer.init(2.0, 0.5, 0.5), // player laser
            .r = std.rand.DefaultPrng.init(0),
        };
    }

    pub fn paint(self: *MainModule) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];
        const tmp2 = g_buffers.buf3[0..];
        const tmp3 = g_buffers.buf4[0..];

        zang.zero(out);

        self.curve_player.paintFromImpulses(AUDIO_SAMPLE_RATE, out, self.iq.getImpulses(), tmp1, tmp2, tmp3, self.frame_index);

        self.iq.flush(self.frame_index, out.len);

        self.frame_index += out.len;

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool) ?common.KeyEvent {
        if (key == c.SDLK_SPACE and down) {
            const base_freq = 440.0;
            const variance = 80.0;

            return common.KeyEvent{
                .iq = &self.iq,
                .freq = base_freq + self.r.random.float(f32) * variance - 0.5 * variance,
            };
        }

        return null;
    }
};
