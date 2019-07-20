// maybe this would be better implemented as a module that just converted
// impulses to impulses (somehow), then you could use it with anything...

const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/c.zig");
const Instrument = @import("modules.zig").HardSquareInstrument;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_arpeggiator
    c\\
    c\\Play an instrument with the keyboard. You can hold
    c\\down multiple notes. The arpeggiator will cycle
    c\\through them lowest to highest.
;

const A4 = 440.0;

const Arpeggiator = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = Instrument.NumTemps;
    pub const Params = struct {
        sample_rate: f32,
        note_held: [common.key_bindings.len]bool,
    };

    iq: zang.Notes(Instrument.Params).ImpulseQueue,
    instrument: Instrument,
    trigger: zang.Trigger(Instrument.Params),
    next_frame: usize,
    last_note: ?usize,

    fn init() Arpeggiator {
        return Arpeggiator {
            .iq = zang.Notes(Instrument.Params).ImpulseQueue.init(),
            .instrument = Instrument.init(),
            .trigger = zang.Trigger(Instrument.Params).init(),
            .next_frame = 0,
            .last_note = null,
        };
    }

    fn paint(self: *Arpeggiator, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const note_duration = @floatToInt(usize, 0.03 * params.sample_rate);

        // TODO - if only one key is held, try to reuse the previous impulse id
        // to prevent the envelope from retriggering on the same note.
        // then replace Gate with Envelope.
        // or maybe not... this is the only example that uses Gate, don't want
        // to lose the coverage

        // also, if possible, when all keys are released, call reset on the
        // arpeggiator, so that whenever you start pressing keys, it starts
        // immediately

        while (self.next_frame < outputs[0].len) {
            const next_note_index = blk: {
                const start = if (self.last_note) |last_note| last_note + 1 else 0;
                var i: usize = 0; while (i < common.key_bindings.len) : (i += 1) {
                    const index = (start + i) % common.key_bindings.len;
                    if (params.note_held[index]) {
                        break :blk index;
                    }
                }
                break :blk null;
            };

            if (next_note_index) |index| {
                const freq = A4 * common.key_bindings[index].rel_freq;
                self.iq.push(self.next_frame, Instrument.Params {
                    .sample_rate = params.sample_rate,
                    .freq = freq,
                    .note_on = true,
                });
                self.last_note = index;
            } else if (self.last_note) |last_note| {
                const freq = A4 * common.key_bindings[last_note].rel_freq;
                self.iq.push(self.next_frame, Instrument.Params {
                    .sample_rate = params.sample_rate,
                    .freq = freq,
                    .note_on = false,
                });
            }

            self.next_frame += note_duration;
        }

        self.next_frame -= outputs[0].len;

        var ctr = self.trigger.counter(span, self.iq.consume());
        while (self.trigger.next(&ctr)) |result| {
            self.instrument.paint(result.span, outputs, temps, result.note_id_changed, result.params);
        }
    }
};

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = Arpeggiator.NumTemps;

    current_params: Arpeggiator.Params,
    iq: zang.Notes(Arpeggiator.Params).ImpulseQueue,
    arpeggiator: Arpeggiator,
    trigger: zang.Trigger(Arpeggiator.Params),

    pub fn init() MainModule {
        return MainModule {
            .current_params = Arpeggiator.Params {
                .sample_rate = AUDIO_SAMPLE_RATE,
                .note_held = [1]bool{false} ** common.key_bindings.len,
            },
            .iq = zang.Notes(Arpeggiator.Params).ImpulseQueue.init(),
            .arpeggiator = Arpeggiator.init(),
            .trigger = zang.Trigger(Arpeggiator.Params).init(),
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        var ctr = self.trigger.counter(span, self.iq.consume());
        while (self.trigger.next(&ctr)) |result| {
            self.arpeggiator.paint(result.span, outputs, temps, result.params);
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        for (common.key_bindings) |kb, i| {
            if (kb.key == key) {
                self.current_params.note_held[i] = down;
                self.iq.push(impulse_frame, self.current_params);
            }
        }
    }
};
