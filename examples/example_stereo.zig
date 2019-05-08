// in this example a stereophonic noise sound oscillates slowly from left to right

const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 4096;

pub const DESCRIPTION =
    c\\example_stereo
    c\\
    c\\A wind-like noise effect slowly
    c\\oscillates between the left and right
    c\\speakers.
    c\\
    c\\This example is not interactive.
;

// take input (-1 to +1) and scale it to (min to max)
fn scaleWave(out: []f32, in: []const f32, tmp0: []f32, min: f32, max: f32) void {
    zang.zero(tmp0);
    zang.multiplyScalar(tmp0, in, (max - min) * 0.5);
    zang.addScalar(out, tmp0, (max - min) * 0.5 + min);
}

// overwrite out with (1 - out)
fn invertWaveInPlace(out: []f32, tmp0: []f32) void {
    zang.zero(tmp0);
    zang.multiplyScalar(tmp0, out, -1.0);
    zang.zero(out);
    zang.addScalar(out, tmp0, 1.0);
}

const NoiseModule = struct {
    pub const NumOutputs = 2;
    pub const NumTemps = 3;
    pub const Params = struct {
        pan: []const f32,
        min: f32,
        max: f32,
        cutoff_frequency: f32,
    };

    noise: zang.Noise,
    flt: zang.Filter,

    fn init(seed: u64) NoiseModule {
        return NoiseModule{
            .noise = zang.Noise.init(seed),
            .flt = zang.Filter.init(),
        };
    }

    fn reset(self: *NoiseModule) void {}

    fn paint(self: *NoiseModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        // temps[0] = filtered noise
        zang.zero(temps[0]);
        zang.zero(temps[1]);
        self.noise.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Noise.Params {});
        self.flt.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[1],
            .filterType = .LowPass,
            .cutoff = zang.constant(zang.cutoffFromFrequency(params.cutoff_frequency, sample_rate)),
            .resonance = 0.4,
        });

        // temps[1] = pan scaled to (min to max)
        zang.zero(temps[1]);
        scaleWave(temps[1], params.pan, temps[2], params.min, params.max);

        // left channel += temps[0] * temps[1]
        zang.multiply(outputs[0], temps[0], temps[1]);

        // temps[1] = 1 - temps[1]
        invertWaveInPlace(temps[1], temps[2]);

        // right channel += temps[0] * temps[1]
        zang.multiply(outputs[1], temps[0], temps[1]);
    }
};

pub const MainModule = struct {
    pub const NumOutputs = 2;
    pub const NumTemps = 4;

    osc: zang.Oscillator,
    noisem0: NoiseModule,
    noisem1: NoiseModule,

    pub fn init() MainModule {
        return MainModule{
            .osc = zang.Oscillator.init(),
            .noisem0 = NoiseModule.init(0),
            .noisem1 = NoiseModule.init(1),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        // temps[0] = slow oscillator representing left/right pan (-1 to +1)
        zang.zero(temps[0]);
        self.osc.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Oscillator.Params {
            .waveform = .Sine,
            .freq = zang.constant(0.1),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });

        // paint two noise voices
        self.noisem0.paint(sample_rate, outputs, [3][]f32{temps[1], temps[2], temps[3]}, NoiseModule.Params {
            .pan = temps[0],
            .min = 0.0,
            .max = 0.5,
            .cutoff_frequency = 320.0,
        });
        self.noisem1.paint(sample_rate, outputs, [3][]f32{temps[1], temps[2], temps[3]}, NoiseModule.Params {
            .pan = temps[0],
            .min = 0.5,
            .max = 1.0,
            .cutoff_frequency = 380.0,
        });
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {}
};
