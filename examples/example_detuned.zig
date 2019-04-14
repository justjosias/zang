// in this example you can play a simple monophonic synth with the keyboard

const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
    buf4: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

var g_note_held: ?i32 = null;

pub const MainModule = struct {
    frame_index: usize,

    noise: zang.Noise,
    noise_filter: zang.Filter,
    iq: zang.ImpulseQueue,
    dc: zang.DC,
    osc: zang.Oscillator,
    env: zang.Envelope,
    main_filter: zang.Filter,

    pub fn init() MainModule {
        return MainModule{
            .frame_index = 0,
            .noise = zang.Noise.init(0),
            // filter frequency set at 4hz. i wanted to go slower but
            // unfortunately at below 4, the filter degrades and the
            // output frequency slowly sinks to nothing
            .noise_filter = zang.Filter.init(.LowPass, zang.cutoffFromFrequency(4.0, AUDIO_SAMPLE_RATE), 0.0),
            .iq = zang.ImpulseQueue.init(),
            .dc = zang.DC.init(),
            .osc = zang.Oscillator.init(.Sawtooth),
            .env = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            }),
            .main_filter = zang.Filter.init(.LowPass, zang.cutoffFromFrequency(880.0, AUDIO_SAMPLE_RATE), 0.9),
        };
    }

    pub fn paint(self: *MainModule) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];
        const tmp2 = g_buffers.buf3[0..];

        zang.zero(out);

        // tmp0 = filtered noise
        zang.zero(tmp1);
        self.noise.paint(tmp1);
        zang.zero(tmp0);
        self.noise_filter.paint(tmp0, tmp1);
        zang.multiplyWithScalar(tmp0, 200.0); // intensity of warble effect

        if (!self.iq.isEmpty()) {
            // add note frequencies onto filtered noise
            self.dc.paintFrequencyFromImpulses(tmp0, self.iq.getImpulses(), self.frame_index);
            // paint with oscillator into tmp1
            zang.zero(tmp1);
            self.osc.paintControlledFrequency(AUDIO_SAMPLE_RATE, tmp1, tmp0);
            // combine with envelope
            zang.zero(tmp0);
            self.env.paintFromImpulses(AUDIO_SAMPLE_RATE, tmp0, self.iq.getImpulses(), self.frame_index);
            zang.zero(tmp2);
            zang.multiply(tmp2, tmp1, tmp0);
            // add main filter
            self.main_filter.paint(out, tmp2);
            // volume boost
            zang.multiplyWithScalar(out, 2.0);
        }

        self.iq.flush(self.frame_index, out.len);

        self.frame_index += out.len;

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool) ?common.KeyEvent {
        const f = zang.note_frequencies;

        if (switch (key) {
            c.SDLK_a => f.C3,
            c.SDLK_w => f.Cs3,
            c.SDLK_s => f.D3,
            c.SDLK_e => f.Ds3,
            c.SDLK_d => f.E3,
            c.SDLK_f => f.F3,
            c.SDLK_t => f.Fs3,
            c.SDLK_g => f.G3,
            c.SDLK_y => f.Gs3,
            c.SDLK_h => f.A3,
            c.SDLK_u => f.As3,
            c.SDLK_j => f.B3,
            c.SDLK_k => f.C4,
            else => null,
        }) |freq| {
            if (down) {
                g_note_held = key;

                return common.KeyEvent{
                    .iq = &self.iq,
                    .freq = freq,
                };
            } else {
                if (if (g_note_held) |nh| nh == key else false) {
                    g_note_held = null;

                    return common.KeyEvent{
                        .iq = &self.iq,
                        .freq = null,
                    };
                }
            }
        }

        return null;
    }
};
