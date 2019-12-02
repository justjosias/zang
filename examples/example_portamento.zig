const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/c.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    \\example_portamento
    \\
    \\Play an instrument with the keyboard. If you press
    \\multiple keys, the frequency will slide toward the
    \\highest held key.
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

    osc: zang.SineOsc,
    env: zang.Envelope,
    porta: zang.Portamento,
    prev_note_on: bool,

    pub fn init() Instrument {
        return Instrument {
            .osc = zang.SineOsc.init(),
            .env = zang.Envelope.init(),
            .porta = zang.Portamento.init(),
            .prev_note_on = false,
        };
    }

    pub fn paint(self: *Instrument, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, note_id_changed: bool, params: Params) void {
        defer self.prev_note_on = params.note_on;

        zang.zero(span, temps[0]);
        self.porta.paint(span, [1][]f32{temps[0]}, [0][]f32{}, note_id_changed, zang.Portamento.Params {
            .sample_rate = params.sample_rate,
            .curve = zang.Painter.Curve { .Cubed = 0.5 },
            .goal = params.freq,
            .note_on = params.note_on,
            .prev_note_on = self.prev_note_on,
        });

        zang.zero(span, temps[1]);
        self.env.paint(span, [1][]f32{temps[1]}, [0][]f32{}, !self.prev_note_on and params.note_on, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack = zang.Painter.Curve { .Cubed = 0.025 },
            .decay = zang.Painter.Curve { .Cubed = 0.1 },
            .release = zang.Painter.Curve { .Cubed = 1.0 },
            .sustain_volume = 0.5,
            .note_on = params.note_on,
        });

        zang.zero(span, temps[2]);
        self.osc.paint(span, [1][]f32{temps[2]}, [0][]f32{}, zang.SineOsc.Params {
            .sample_rate = params.sample_rate,
            .freq = zang.buffer(temps[0]),
            .phase = zang.constant(0.0),
        });

        zang.multiply(span, outputs[0], temps[1], temps[2]);
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
            const key_flag = @as(u64, 1) << key_index;
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
