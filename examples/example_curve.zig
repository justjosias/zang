const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_curve
    c\\
    c\\Trigger a weird sound effect with the
    c\\keyboard. The sound is defined using a
    c\\curve, and scales with the frequency of
    c\\the key you press.
;

const carrier_curve = []zang.CurveNode {
    zang.CurveNode { .t = 0.0, .value = 440.0 },
    zang.CurveNode { .t = 0.5, .value = 880.0 },
    zang.CurveNode { .t = 1.0, .value = 110.0 },
    zang.CurveNode { .t = 1.5, .value = 660.0 },
    zang.CurveNode { .t = 2.0, .value = 330.0 },
    zang.CurveNode { .t = 3.9, .value = 20.0 },
};

const modulator_curve = []zang.CurveNode {
    zang.CurveNode { .t = 0.0, .value = 110.0 },
    zang.CurveNode { .t = 1.5, .value = 55.0 },
    zang.CurveNode { .t = 3.0, .value = 220.0 },
};

const CurvePlayer = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct { rel_freq: f32 };

    carrier_curve: zang.Curve,
    carrier: zang.Oscillator,
    modulator_curve: zang.Curve,
    modulator: zang.Oscillator,

    fn init() CurvePlayer {
        return CurvePlayer {
            .carrier_curve = zang.Curve.init(),
            .carrier = zang.Oscillator.init(),
            .modulator_curve = zang.Curve.init(),
            .modulator = zang.Oscillator.init(),
        };
    }

    fn reset(self: *CurvePlayer) void {
        self.carrier_curve.reset();
        self.modulator_curve.reset();
    }

    fn paint(self: *CurvePlayer, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const freq_mul = params.rel_freq;

        zang.zero(temps[0]);
        self.modulator_curve.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Curve.Params {
            .function = .SmoothStep,
            .curve = modulator_curve,
            .freq_mul = freq_mul,
        });
        zang.zero(temps[1]);
        self.modulator.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Oscillator.Params {
            .waveform = .Sine,
            .freq = zang.buffer(temps[0]),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });
        zang.zero(temps[0]);
        self.carrier_curve.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Curve.Params {
            .function = .SmoothStep,
            .curve = carrier_curve,
            .freq_mul = freq_mul,
        });
        self.carrier.paint(sample_rate, outputs, [0][]f32{}, zang.Oscillator.Params {
            .waveform = .Sine,
            .freq = zang.buffer(temps[0]),
            .phase = zang.buffer(temps[1]),
            .colour = 0.5,
        });
    }
};

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;

    iq: zang.Notes(CurvePlayer.Params).ImpulseQueue,
    curve_player: zang.Triggerable(CurvePlayer),

    pub fn init() MainModule {
        return MainModule {
            .iq = zang.Notes(CurvePlayer.Params).ImpulseQueue.init(),
            .curve_player = zang.initTriggerable(CurvePlayer.init()),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        self.curve_player.paintFromImpulses(sample_rate, outputs, temps, self.iq.consume());
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (down) {
            if (common.getKeyRelFreq(key)) |rel_freq| {
                self.iq.push(impulse_frame, CurvePlayer.Params { .rel_freq = rel_freq });
            }
        }
    }
};
