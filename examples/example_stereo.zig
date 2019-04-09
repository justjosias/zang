// in this example a stereophonic noise sound oscillates slowly from left to right

const std = @import("std");
const harold = @import("harold");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = harold.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 4096;
pub const AUDIO_CHANNELS = 2;

const NoiseModule = struct {
    noise: harold.Noise,
    flt: harold.Filter,

    fn init(seed: u64, freq: f32) NoiseModule {
        return NoiseModule{
            .noise = harold.Noise.init(seed),
            .flt = harold.Filter.init(.LowPass, freq, 0.4),
        };
    }

    fn paint(self: *NoiseModule, out: []f32, tmp0: []f32) void {
        harold.zero(tmp0);
        self.noise.paint(tmp0);
        self.flt.paint(AUDIO_SAMPLE_RATE, out, tmp0);
    }
};

// take input (-1 to +1) and scale it to (min to max)
fn scaleWave(out: []f32, in: []f32, tmp0: []f32, min: f32, max: f32) void {
    harold.zero(tmp0);
    harold.multiplyScalar(tmp0, in, (max - min) * 0.5);
    harold.addScalar(out, tmp0, (max - min) * 0.5 + min);
}

// overwrite out with (1 - out)
fn invertWaveInPlace(out: []f32, tmp0: []f32) void {
    harold.zero(tmp0);
    harold.multiplyScalar(tmp0, out, -1.0);
    harold.zero(out);
    harold.addScalar(out, tmp0, 1.0);
}

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

    osc: harold.Oscillator,
    noisem0: NoiseModule,
    noisem1: NoiseModule,

    pub fn init() MainModule {
        return MainModule{
            .frame_index = 0,
            .osc = harold.Oscillator.init(.Sine),
            .noisem0 = NoiseModule.init(0, 320.0),
            .noisem1 = NoiseModule.init(1, 380.0),
        };
    }

    fn paintOne(out0: []f32, out1: []f32, noisem: *NoiseModule, pan: []f32, tmp0: []f32, tmp1: []f32, tmp2: []f32, min: f32, max: f32) void {
        // tmp0 = filtered noise
        harold.zero(tmp0);
        noisem.paint(tmp0, tmp1);

        // tmp1 = pan scaled to (min to max)
        harold.zero(tmp1);
        scaleWave(tmp1, pan, tmp2, min, max);

        // left channel += tmp0 * tmp1
        harold.multiply(out0, tmp0, tmp1);

        // tmp1 = 1 - tmp1
        invertWaveInPlace(tmp1, tmp2);

        // right channel += tmp0 * tmp1
        harold.multiply(out1, tmp0, tmp1);
    }

    pub fn paint(self: *MainModule) [AUDIO_CHANNELS][]const f32 {
        const out0 = g_buffers.buf0[0..];
        const out1 = g_buffers.buf1[0..];
        const tmp0 = g_buffers.buf2[0..];
        const tmp1 = g_buffers.buf3[0..];
        const tmp2 = g_buffers.buf4[0..];
        const tmp3 = g_buffers.buf5[0..];

        harold.zero(out0);
        harold.zero(out1);

        // tmp0 = slow oscillator representing left/right pan (-1 to +1)
        harold.zero(tmp0);
        self.osc.freq = 0.1;
        self.osc.paint(AUDIO_SAMPLE_RATE, tmp0);

        // paint two noise voices
        paintOne(out0, out1, &self.noisem0, tmp0, tmp1, tmp2, tmp3, 0.0, 0.5);
        paintOne(out0, out1, &self.noisem1, tmp0, tmp1, tmp2, tmp3, 0.5, 1.0);

        self.frame_index += out0.len;

        return [AUDIO_CHANNELS][]const f32 {
            out0,
            out1,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool) ?common.KeyEvent {
        return null;
    }
};
