const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/c.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_portamento
    c\\
    c\\Play an "instrument" with the keyboard. (The tone is
    c\\created using noise and a resonant low-pass filter.)
    c\\
    c\\If you press multiple keys, the frequency will slide
    c\\toward the highest held key.
;

const a4 = 440.0;

pub const Instrument = struct {
    pub const num_outputs = 1;
    pub const num_temps = 3;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    noise: zang.Noise,
    env: zang.Envelope,
    porta: zang.Portamento,
    flt: zang.Filter,

    pub fn init() Instrument {
        return Instrument {
            .noise = zang.Noise.init(0),
            .env = zang.Envelope.init(),
            .porta = zang.Portamento.init(),
            .flt = zang.Filter.init(),
        };
    }

    pub fn paint(self: *Instrument, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, note_id_changed: bool, params: Params) void {
        zang.zero(span, temps[0]);
        self.noise.paint(span, [1][]f32{temps[0]}, [0][]f32{}, zang.Noise.Params {});
        zang.zero(span, temps[1]);
        self.porta.paint(span, [1][]f32{temps[1]}, [0][]f32{}, zang.Portamento.Params {
            .sample_rate = params.sample_rate,
            .mode = .CatchUp,
            .velocity = 8.0,
            .value = zang.cutoffFromFrequency(params.freq, params.sample_rate),
            .note_on = params.note_on,
        });
        zang.zero(span, temps[2]);
        self.flt.paint(span, [1][]f32{temps[2]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[0],
            .filter_type = .LowPass,
            .cutoff = zang.buffer(temps[1]),
            .resonance = 0.985,
        });
        zang.zero(span, temps[0]);
        self.env.paint(span, [1][]f32{temps[0]}, [0][]f32{}, note_id_changed, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack = zang.Envelope.Curve { .curve_type = .Cubed, .duration = 0.025 },
            .decay = zang.Envelope.Curve { .curve_type = .Cubed, .duration = 0.1 },
            .release = zang.Envelope.Curve { .curve_type = .Cubed, .duration = 1.0 },
            .sustain_volume = 0.5,
            .note_on = params.note_on,
        });
        zang.multiply(span, outputs[0], temps[2], temps[0]);
    }
};

pub const MainModule = struct {
    pub const num_outputs = 1;
    pub const num_temps = 3;

    keys_held: u64,
    iq: zang.Notes(Instrument.Params).ImpulseQueue,
    idgen: zang.IdGenerator,
    instr: Instrument,
    trigger: zang.Trigger(Instrument.Params),

    pub fn init() MainModule {
        return MainModule {
            .keys_held = 0,
            .iq = zang.Notes(Instrument.Params).ImpulseQueue.init(),
            .idgen = zang.IdGenerator.init(),
            .instr = Instrument.init(),
            .trigger = zang.Trigger(Instrument.Params).init(),
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        var ctr = self.trigger.counter(span, self.iq.consume());
        while (self.trigger.next(&ctr)) |result| {
            self.instr.paint(result.span, outputs, temps, result.note_id_changed, result.params);
        }
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
                    self.iq.push(impulse_frame, self.idgen.nextId(), Instrument.Params {
                        .sample_rate = AUDIO_SAMPLE_RATE,
                        .freq = a4 * kb.rel_freq,
                        .note_on = true,
                    });
                }
            } else {
                self.keys_held &= ~key_flag;

                if (self.keys_held == 0) {
                    self.iq.push(impulse_frame, self.idgen.nextId(), Instrument.Params {
                        .sample_rate = AUDIO_SAMPLE_RATE,
                        .freq = a4 * kb.rel_freq,
                        .note_on = false,
                    });
                } else {
                    const rel_freq = common.key_bindings[63 - @clz(u64, self.keys_held)].rel_freq;
                    self.iq.push(impulse_frame, self.idgen.nextId(), Instrument.Params {
                        .sample_rate = AUDIO_SAMPLE_RATE,
                        .freq = a4 * rel_freq,
                        .note_on = true,
                    });
                }
            }
        }
    }
};
