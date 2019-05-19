const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/c.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 4096;

pub const DESCRIPTION =
    c\\example_stereo
    c\\
    c\\A wind-like noise effect slowly oscillates between the
    c\\left and right speakers.
    c\\
    c\\This example is not interactive.
;

// take input (-1 to +1) and scale it to (min to max)
fn scaleWave(span: zang.Span, out: []f32, in: []const f32, tmp0: []f32, min: f32, max: f32) void {
    zang.zero(span, tmp0);
    zang.multiplyScalar(span, tmp0, in, (max - min) * 0.5);
    zang.addScalar(span, out, tmp0, (max - min) * 0.5 + min);
}

// overwrite out with (1 - out)
fn invertWaveInPlace(span: zang.Span, out: []f32, tmp0: []f32) void {
    zang.zero(span, tmp0);
    zang.multiplyScalar(span, tmp0, out, -1.0);
    zang.zero(span, out);
    zang.addScalar(span, out, tmp0, 1.0);
}

const NoiseModule = struct {
    pub const NumOutputs = 2;
    pub const NumTemps = 3;
    pub const Params = struct {
        sample_rate: f32,
        pan: []const f32,
        min: f32,
        max: f32,
        cutoff_frequency: f32,
    };

    noise: zang.Noise,
    flt: zang.Filter,

    fn init(seed: u64) NoiseModule {
        return NoiseModule {
            .noise = zang.Noise.init(seed),
            .flt = zang.Filter.init(),
        };
    }

    fn paint(self: *NoiseModule, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        // temps[0] = filtered noise
        zang.zero(span, temps[0]);
        zang.zero(span, temps[1]);
        self.noise.paint(span, [1][]f32{temps[1]}, [0][]f32{}, zang.Noise.Params {});
        self.flt.paint(span, [1][]f32{temps[0]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[1],
            .filterType = .LowPass,
            .cutoff = zang.constant(zang.cutoffFromFrequency(params.cutoff_frequency, params.sample_rate)),
            .resonance = 0.4,
        });

        // increase volume
        zang.multiplyWithScalar(span, temps[0], 4.0);

        // temps[1] = pan scaled to (min to max)
        zang.zero(span, temps[1]);
        scaleWave(span, temps[1], params.pan, temps[2], params.min, params.max);

        // left channel += temps[0] * temps[1]
        zang.multiply(span, outputs[0], temps[0], temps[1]);

        // temps[1] = 1 - temps[1]
        invertWaveInPlace(span, temps[1], temps[2]);

        // right channel += temps[0] * temps[1]
        zang.multiply(span, outputs[1], temps[0], temps[1]);
    }
};

pub const MainModule = struct {
    pub const NumOutputs = 2;
    pub const NumTemps = 4;

    osc: zang.Oscillator,
    noisem0: NoiseModule,
    noisem1: NoiseModule,

    pub fn init() MainModule {
        return MainModule {
            .osc = zang.Oscillator.init(),
            .noisem0 = NoiseModule.init(0),
            .noisem1 = NoiseModule.init(1),
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        const sample_rate = AUDIO_SAMPLE_RATE;

        // temps[0] = slow oscillator representing left/right pan (-1 to +1)
        zang.zero(span, temps[0]);
        self.osc.paint(span, [1][]f32{temps[0]}, [0][]f32{}, zang.Oscillator.Params {
            .sample_rate = sample_rate,
            .waveform = .Sine,
            .freq = zang.constant(0.1),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });

        // paint two noise voices
        self.noisem0.paint(span, outputs, [3][]f32{temps[1], temps[2], temps[3]}, NoiseModule.Params {
            .sample_rate = sample_rate,
            .pan = temps[0],
            .min = 0.0,
            .max = 0.5,
            .cutoff_frequency = 320.0,
        });
        self.noisem1.paint(span, outputs, [3][]f32{temps[1], temps[2], temps[3]}, NoiseModule.Params {
            .sample_rate = sample_rate,
            .pan = temps[0],
            .min = 0.5,
            .max = 1.0,
            .cutoff_frequency = 380.0,
        });
    }
};
