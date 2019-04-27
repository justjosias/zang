// in this example a stereophonic noise sound oscillates slowly from left to right

const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 4096;
pub const AUDIO_CHANNELS = 2;

pub const MyNoteParams = NoiseModule.Params;
pub const MyNotes = zang.Notes(MyNoteParams);

// take input (-1 to +1) and scale it to (min to max)
fn scaleWave(out: []f32, in: []f32, tmp0: []f32, min: f32, max: f32) void {
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
    pub const NumInputs = 1;
    pub const NumTemps = 3;
    pub const Params = struct {
        min: f32,
        max: f32,
        cutoff_frequency: f32,
    };

    noise: zang.Noise,
    flt: zang.Filter,

    fn init(seed: u64) NoiseModule {
        return NoiseModule{
            .noise = zang.Noise.init(seed),
            .flt = zang.Filter.init(.LowPass),
        };
    }

    fn reset(self: *NoiseModule) void {}

    fn paintSpan(self: *NoiseModule, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const pan = inputs[0];

        // temps[0] = filtered noise
        zang.zero(temps[0]);
        zang.zero(temps[1]);
        self.noise.paintSpan(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, [0][]f32{}, zang.Noise.Params {});
        self.flt.paintSpan(sample_rate, [1][]f32{temps[0]}, [1][]f32{temps[1]}, [0][]f32{}, zang.Filter.Params {
            .cutoff = zang.cutoffFromFrequency(params.cutoff_frequency, sample_rate),
            .resonance = 0.4,
        });

        // temps[1] = pan scaled to (min to max)
        zang.zero(temps[1]);
        scaleWave(temps[1], pan, temps[2], params.min, params.max);

        // left channel += temps[0] * temps[1]
        zang.multiply(outputs[0], temps[0], temps[1]);

        // temps[1] = 1 - temps[1]
        invertWaveInPlace(temps[1], temps[2]);

        // right channel += temps[0] * temps[1]
        zang.multiply(outputs[1], temps[0], temps[1]);
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
    buf4: [AUDIO_BUFFER_SIZE]f32,
    buf5: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    frame_index: usize,

    osc: zang.Oscillator,
    noisem0: NoiseModule,
    noisem1: NoiseModule,

    pub fn init() MainModule {
        return MainModule{
            .frame_index = 0,
            .osc = zang.Oscillator.init(.Sine),
            .noisem0 = NoiseModule.init(0),
            .noisem1 = NoiseModule.init(1),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32) [AUDIO_CHANNELS][]const f32 {
        const out0 = g_buffers.buf0[0..];
        const out1 = g_buffers.buf1[0..];
        const tmp0 = g_buffers.buf2[0..];
        const tmp1 = g_buffers.buf3[0..];
        const tmp2 = g_buffers.buf4[0..];
        const tmp3 = g_buffers.buf5[0..];

        zang.zero(out0);
        zang.zero(out1);

        // tmp0 = slow oscillator representing left/right pan (-1 to +1)
        zang.zero(tmp0);
        self.osc.paintSpan(sample_rate, [1][]f32{tmp0}, [0][]f32{}, [0][]f32{}, zang.Oscillator.Params {
            .freq = 0.1,
        });

        // paint two noise voices
        self.noisem0.paintSpan(sample_rate, [2][]f32{out0, out1}, [1][]f32{tmp0}, [3][]f32{tmp1, tmp2, tmp3}, NoiseModule.Params {
            .min = 0.0,
            .max = 0.5,
            .cutoff_frequency = 320.0,
        });
        self.noisem1.paintSpan(sample_rate, [2][]f32{out0, out1}, [1][]f32{tmp0}, [3][]f32{tmp1, tmp2, tmp3}, NoiseModule.Params {
            .min = 0.5,
            .max = 1.0,
            .cutoff_frequency = 380.0,
        });

        self.frame_index += out0.len;

        return [AUDIO_CHANNELS][]const f32 {
            out0,
            out1,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, out_iq: **MyNotes.ImpulseQueue, out_params: *MyNoteParams) bool {
        return false;
    }
};
