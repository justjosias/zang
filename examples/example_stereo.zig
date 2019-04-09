// in this example a stereophonic noise sound oscillates slowly from left to right

const std = @import("std");
const harold = @import("harold");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = harold.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 4096;
pub const AUDIO_CHANNELS = 2;

fn AudioBuffers(comptime buffer_size: usize) type {
    return struct {
        buf0: [AUDIO_BUFFER_SIZE]f32,
        buf1: [AUDIO_BUFFER_SIZE]f32,
        buf2: [AUDIO_BUFFER_SIZE]f32,
        buf3: [AUDIO_BUFFER_SIZE]f32,
        buf4: [AUDIO_BUFFER_SIZE]f32,
        buf5: [AUDIO_BUFFER_SIZE]f32,
    };
}

pub const AudioState = struct {
    frame_index: usize,

    osc: harold.Oscillator,

    noise0: harold.Noise,
    flt0: harold.Filter,

    noise1: harold.Noise,
    flt1: harold.Filter,
};

var buffers: AudioBuffers(AUDIO_BUFFER_SIZE) = undefined;

pub fn initAudioState() AudioState {
    return AudioState{
        .frame_index = 0,
        .osc = harold.Oscillator.init(.Sine),
        .noise0 = harold.Noise.init(0),
        .flt0 = harold.Filter.init(.LowPass, 320.0, 0.4),
        .noise1 = harold.Noise.init(1),
        .flt1 = harold.Filter.init(.LowPass, 380.0, 0.4),
    };
}

pub fn paint(as: *AudioState) [AUDIO_CHANNELS][]const f32 {
    const out0 = buffers.buf0[0..];
    const out1 = buffers.buf1[0..];
    const tmp0 = buffers.buf2[0..];
    const tmp1 = buffers.buf3[0..];
    const tmp2 = buffers.buf4[0..];
    const tmp3 = buffers.buf5[0..];

    harold.zero(out0);
    harold.zero(out1);

    // tmp0 = low frequency oscillator (-1 to 1)
    harold.zero(tmp0);
    as.osc.freq = 0.1;
    as.osc.paint(AUDIO_SAMPLE_RATE, tmp0);

    // NOISE VOICE 1

    // tmp1 = filtered noise
    harold.zero(tmp2);
    as.noise0.paint(tmp2);
    harold.zero(tmp1);
    as.flt0.paint(AUDIO_SAMPLE_RATE, tmp1, tmp2);

    // tmp2 = tmp0 scaled to (0 to 0.5)
    harold.zero(tmp3);
    harold.multiplyScalar(tmp3, tmp0, 0.25);
    harold.zero(tmp2);
    harold.addScalar(tmp2, tmp3, 0.25);

    // left channel += tmp1 * tmp2
    harold.multiply(out0, tmp1, tmp2);

    // tmp2 = 1 - tmp2
    harold.zero(tmp3);
    harold.multiplyScalar(tmp3, tmp2, -1.0);
    harold.zero(tmp2);
    harold.addScalar(tmp2, tmp3, 1.0);

    // right channel += tmp1 * tmp2
    harold.multiply(out1, tmp1, tmp2);

    // NOISE VOICE 2

    // tmp1 = filtered noise
    harold.zero(tmp2);
    as.noise1.paint(tmp2);
    harold.zero(tmp1);
    as.flt1.paint(AUDIO_SAMPLE_RATE, tmp1, tmp2);

    // tmp2 = tmp0 scaled to (0.5 to 1)
    harold.zero(tmp3);
    harold.multiplyScalar(tmp3, tmp0, 0.25);
    harold.zero(tmp2);
    harold.addScalar(tmp2, tmp3, 0.75);

    // left channel += tmp1 * tmp2
    harold.multiply(out0, tmp1, tmp2);

    // tmp2 = 1 - tmp2
    harold.zero(tmp3);
    harold.multiplyScalar(tmp3, tmp2, -1.0);
    harold.zero(tmp2);
    harold.addScalar(tmp2, tmp3, 1.0);

    // right channel += tmp1 * tmp2
    harold.multiply(out1, tmp1, tmp2);

    as.frame_index += out0.len;

    return [AUDIO_CHANNELS][]const f32 {
        out0,
        out1,
    };
}

pub fn keyEvent(audio_state: *AudioState, key: i32, down: bool) ?common.KeyEvent {
    return null;
}
