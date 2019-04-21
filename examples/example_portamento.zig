const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet").NoteFrequencies(440.0);
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
} = undefined;

pub const MainModule = struct {
    iq: zang.ImpulseQueue,
    keys_held: u32,
    noise: zang.Noise,
    env: zang.Envelope,
    env_trigger: zang.Trigger(zang.Envelope),
    porta: zang.Portamento,
    porta_trigger: zang.Trigger(zang.Portamento),
    flt: zang.Filter,

    pub fn init() MainModule {
        // FIXME - we don't initialize oscillator with a frequency, why should
        // filter be initialized? i don't like using sample rate in the init
        // function
        // maybe all modules should have an enabled/disabled switch (and be
        // disabled by default)
        const cutoff = zang.cutoffFromFrequency(note_frequencies.C5, AUDIO_SAMPLE_RATE);

        return MainModule{
            .iq = zang.ImpulseQueue.init(),
            .keys_held = 0,
            .noise = zang.Noise.init(0),
            .env = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            }),
            .env_trigger = zang.Trigger(zang.Envelope).init(),
            .porta = zang.Portamento.init(400.0),
            .porta_trigger = zang.Trigger(zang.Portamento).init(),
            .flt = zang.Filter.init(.LowPass, cutoff, 0.985),
        };
    }

    pub fn paint(self: *MainModule) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];
        const tmp2 = g_buffers.buf3[0..];

        zang.zero(out);

        {
            const impulses = self.iq.consume();
            var i: usize = undefined;

            zang.zero(tmp0);
            self.noise.paint(tmp0);

            zang.zero(tmp1);
            self.porta_trigger.paintFromImpulses(&self.porta, AUDIO_SAMPLE_RATE, tmp1, impulses, [0][]f32{});
            // FIXME do this to the impulses, not the buffer
            i = 0; while (i < tmp1.len) : (i += 1) {
                tmp1[i] = zang.cutoffFromFrequency(tmp1[i], AUDIO_SAMPLE_RATE);
            }

            zang.zero(tmp2);
            self.flt.paintControlledCutoff(AUDIO_SAMPLE_RATE, tmp2, tmp0, tmp1);

            zang.zero(tmp0);
            self.env_trigger.paintFromImpulses(&self.env, AUDIO_SAMPLE_RATE, tmp0, impulses, [0][]f32{});

            zang.multiply(out, tmp2, tmp0);
        }

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    // this is a bit different from the other examples. i'm mimicking the
    // behaviour of analog monophonic synths with portamento:
    // - the frequency is always that of the highest key held
    // - note-off only occurs when all keys are released
    pub fn keyEvent(self: *MainModule, key: i32, down: bool) ?common.KeyEvent {
        const f = note_frequencies;

        const key_freqs = [13]f32 {
            f.C4,
            f.Cs4,
            f.D4,
            f.Ds4,
            f.E4,
            f.F4,
            f.Fs4,
            f.G4,
            f.Gs4,
            f.A4,
            f.As4,
            f.B4,
            f.C5,
        };

        if (switch (key) {
            c.SDLK_a => u5(0),
            c.SDLK_w => u5(1),
            c.SDLK_s => u5(2),
            c.SDLK_e => u5(3),
            c.SDLK_d => u5(4),
            c.SDLK_f => u5(5),
            c.SDLK_t => u5(6),
            c.SDLK_g => u5(7),
            c.SDLK_y => u5(8),
            c.SDLK_h => u5(9),
            c.SDLK_u => u5(10),
            c.SDLK_j => u5(11),
            c.SDLK_k => u5(12),
            else => null,
        }) |key_index| {
            const key_flag = u32(1) << key_index;
            const prev_keys_held = self.keys_held;

            if (down) {
                self.keys_held |= key_flag;

                if (key_flag > prev_keys_held) {
                    return common.KeyEvent{
                        .iq = &self.iq,
                        .freq = key_freqs[key_index],
                    };
                }
            } else {
                self.keys_held &= ~key_flag;

                if (self.keys_held == 0) {
                    return common.KeyEvent{
                        .iq = &self.iq,
                        .freq = null,
                    };
                } else {
                    return common.KeyEvent{
                        .iq = &self.iq,
                        .freq = key_freqs[31 - @clz(self.keys_held)],
                    };
                }
            }
        }

        return null;
    }
};
