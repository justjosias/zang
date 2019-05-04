const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

const A4 = 440.0;

pub const Instrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 3;
    pub const Params = struct { freq: f32, note_on: bool };

    noise: zang.Noise,
    env: zang.Envelope,
    porta: zang.Portamento,
    flt: zang.Filter,

    pub fn init() Instrument {
        return Instrument {
            .noise = zang.Noise.init(0),
            .env = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            }),
            .porta = zang.Portamento.init(),
            .flt = zang.Filter.init(),
        };
    }

    pub fn reset(self: *Instrument) void {}

    pub fn paint(self: *Instrument, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        zang.zero(temps[0]);
        self.noise.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Noise.Params {});
        zang.zero(temps[1]);
        self.porta.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Portamento.Params {
            .velocity = 0.05,
            .value = zang.cutoffFromFrequency(params.freq, sample_rate),
            .note_on = params.note_on,
        });
        zang.zero(temps[2]);
        self.flt.paint(sample_rate, [1][]f32{temps[2]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[0],
            .filterType = .LowPass,
            .cutoff = zang.buffer(temps[1]),
            .resonance = 0.985,
        });
        zang.zero(temps[0]);
        self.env.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Envelope.Params {
            .note_on = params.note_on,
        });
        zang.multiply(outputs[0], temps[2], temps[0]);
    }
};

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 3;

    iq: zang.Notes(Instrument.Params).ImpulseQueue,
    keys_held: u64,
    instr: zang.Triggerable(Instrument),

    pub fn init() MainModule {
        return MainModule {
            .iq = zang.Notes(Instrument.Params).ImpulseQueue.init(),
            .keys_held = 0,
            .instr = zang.initTriggerable(Instrument.init()),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        self.instr.paintFromImpulses(sample_rate, outputs, temps, self.iq.consume());
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
                    self.iq.push(impulse_frame, Instrument.Params { .freq = A4 * kb.rel_freq, .note_on = true });
                }
            } else {
                self.keys_held &= ~key_flag;

                if (self.keys_held == 0) {
                    self.iq.push(impulse_frame, Instrument.Params { .freq = A4 * kb.rel_freq, .note_on = false });
                } else {
                    const rel_freq = common.key_bindings[63 - @clz(self.keys_held)].rel_freq;
                    self.iq.push(impulse_frame, Instrument.Params { .freq = A4 * rel_freq, .note_on = true });
                }
            }
        }
    }
};
