// in this example a weird sound plays when you hit a key

const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet").NoteFrequencies(440.0);
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

const CurvePlayer = struct {
    pub const NumTempBufs = 2;

    carrier_curve: zang.Curve,
    carrier: zang.Oscillator,
    modulator_curve: zang.Curve,
    modulator: zang.Oscillator,

    fn init() CurvePlayer {
        return CurvePlayer {
            .carrier_curve = zang.Curve.init(.SmoothStep, []zang.CurveNode {
                zang.CurveNode{ .t = 0.0, .value = 440.0 },
                zang.CurveNode{ .t = 0.5, .value = 880.0 },
                zang.CurveNode{ .t = 1.0, .value = 110.0 },
                zang.CurveNode{ .t = 1.5, .value = 660.0 },
                zang.CurveNode{ .t = 2.0, .value = 330.0 },
                zang.CurveNode{ .t = 3.9, .value = 20.0 },
            }),
            .carrier = zang.Oscillator.init(.Sine),
            .modulator_curve = zang.Curve.init(.SmoothStep, []zang.CurveNode {
                zang.CurveNode{ .t = 0.0, .value = 110.0 },
                zang.CurveNode{ .t = 1.5, .value = 55.0 },
                zang.CurveNode{ .t = 3.0, .value = 220.0 },
            }),
            .modulator = zang.Oscillator.init(.Sine),
        };
    }

    fn paint(self: *CurvePlayer, sample_rate: f32, out: []f32, note_on: bool, freq: f32, tmp: [NumTempBufs][]f32) void {
        const freq_mul = freq / 440.0;

        zang.zero(tmp[0]);
        self.modulator_curve.paint(sample_rate, tmp[0], freq_mul);
        zang.zero(tmp[1]);
        self.modulator.paintControlledFrequency(sample_rate, tmp[1], tmp[0]);
        zang.zero(tmp[0]);
        self.carrier_curve.paint(sample_rate, tmp[0], freq_mul);
        self.carrier.paintControlledPhaseAndFrequency(sample_rate, out, tmp[1], tmp[0]);
    }

    fn reset(self: *CurvePlayer) void {
        self.carrier_curve.reset();
        self.modulator_curve.reset();
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    iq: zang.ImpulseQueue,
    curve_player: CurvePlayer,
    curve_trigger: zang.Trigger(CurvePlayer),

    pub fn init() MainModule {
        return MainModule{
            .iq = zang.ImpulseQueue.init(),
            .curve_player = CurvePlayer.init(),
            .curve_trigger = zang.Trigger(CurvePlayer).init(),
        };
    }

    pub fn paint(self: *MainModule) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];

        zang.zero(out);

        self.curve_trigger.paintFromImpulses(&self.curve_player, AUDIO_SAMPLE_RATE, out, self.iq.consume(), [2][]f32{tmp0, tmp1});

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool) ?common.KeyEvent {
        const f = note_frequencies;

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
