const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

const A4 = 440.0;

const MyNoteParams = struct {
    freq: f32,
    note_on: bool,
};
const MyNotes = zang.Notes(MyNoteParams);

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    iq: MyNotes.ImpulseQueue,
    keys_held: u64,
    noise: zang.Noise,
    env: zang.Triggerable(zang.Envelope),
    porta: zang.Triggerable(zang.Portamento),
    flt: zang.Filter,

    pub fn init() MainModule {
        return MainModule {
            .iq = MyNotes.ImpulseQueue.init(),
            .keys_held = 0,
            .noise = zang.Noise.init(0),
            .env = zang.initTriggerable(zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            })),
            .porta = zang.initTriggerable(zang.Portamento.init()),
            .flt = zang.Filter.init(),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];
        const tmp2 = g_buffers.buf3[0..];

        zang.zero(out);

        {
            const impulses = self.iq.consume();
            var i: usize = undefined;

            zang.zero(tmp0);
            self.noise.paint(sample_rate, [1][]f32{tmp0}, [0][]f32{}, zang.Noise.Params {});

            zang.zero(tmp1);
            {
                var conv = zang.ParamsConverter(MyNoteParams, zang.Portamento.Params).init();
                for (conv.getPairs(impulses)) |*pair| {
                    pair.dest = zang.Portamento.Params {
                        .velocity = 0.05,
                        .value = zang.cutoffFromFrequency(pair.source.freq, sample_rate),
                        .note_on = pair.source.note_on,
                    };
                }
                self.porta.paintFromImpulses(sample_rate, [1][]f32{tmp1}, [0][]f32{}, conv.getImpulses());
            }

            zang.zero(tmp2);
            self.flt.paintControlledCutoff(sample_rate, tmp2, tmp0, .LowPass, tmp1, 0.985);

            zang.zero(tmp0);
            {
                var conv = zang.ParamsConverter(MyNoteParams, zang.Envelope.Params).init();
                self.env.paintFromImpulses(sample_rate, [1][]f32{tmp0}, [0][]f32{}, conv.autoStructural(impulses));
            }

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
    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        for (common.key_bindings) |kb, i| {
            if (kb.key != key) {
                continue;
            }

            const key_index = @intCast(u6, i);
            const key_flag = u64(1) << key_index;
            const prev_keys_held = self.keys_held;

            if (down) {
                self.keys_held |= key_flag;

                if (key_flag > prev_keys_held) {
                    self.iq.push(impulse_frame, MyNoteParams { .freq = A4 * kb.rel_freq, .note_on = true });
                }
            } else {
                self.keys_held &= ~key_flag;

                if (self.keys_held == 0) {
                    self.iq.push(impulse_frame, MyNoteParams { .freq = A4 * kb.rel_freq, .note_on = false });
                } else {
                    const rel_freq = common.key_bindings[63 - @clz(self.keys_held)].rel_freq;
                    self.iq.push(impulse_frame, MyNoteParams { .freq = A4 * rel_freq, .note_on = true });
                }
            }
        }
    }
};
