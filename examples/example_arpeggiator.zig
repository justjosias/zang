// maybe this would be better implemented as a module that just converted
// impulses to impulses (somehow), then you could use it with anything...

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

const Arpeggiator = struct {
    pub const NumOutputs = 1;
    pub const NumInputs = 0;
    pub const NumTemps = 2;
    pub const Params = struct {
        note_held: [common.key_bindings.len]bool,
    };
    pub const InnerParams = struct {
        freq: f32,
        note_on: bool,
    };

    iq: zang.Notes(InnerParams).ImpulseQueue,
    osc: zang.Triggerable(zang.Oscillator),
    gate: zang.Triggerable(zang.Gate),
    next_frame: usize,
    last_note: ?usize,

    fn init() Arpeggiator {
        return Arpeggiator {
            .iq = zang.Notes(InnerParams).ImpulseQueue.init(),
            .osc = zang.initTriggerable(zang.Oscillator.init()),
            .gate = zang.initTriggerable(zang.Gate.init()),
            .next_frame = 0,
            .last_note = null,
        };
    }

    fn reset(self: *Arpeggiator) void {}

    fn paintSpan(self: *Arpeggiator, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const out = outputs[0];
        const note_duration = @floatToInt(usize, 0.03 * sample_rate);

        // TODO - if only one key is held, try to reuse the previous impulse id
        // to prevent the envelope from retriggering on the same note.
        // then replace Gate with Envelope.
        // or maybe not... this is the only example that uses Gate, don't want
        // to lose the coverage

        // also, if possible, when all keys are released, call reset on the
        // arpeggiator, so that whenever you start pressing keys, it starts
        // immediately

        while (self.next_frame < out.len) {
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
                self.iq.push(self.next_frame, InnerParams { .freq = freq, .note_on = true });
                self.last_note = index;
            } else if (self.last_note) |last_note| {
                const freq = A4 * common.key_bindings[last_note].rel_freq;
                self.iq.push(self.next_frame, InnerParams { .freq = freq, .note_on = false });
            }

            self.next_frame += note_duration;
        }

        self.next_frame -= out.len;

        const impulses = self.iq.consume();

        zang.zero(temps[0]);
        {
            var conv = zang.ParamsConverter(InnerParams, zang.Oscillator.Params).init();
            for (conv.getPairs(impulses)) |*pair| {
                pair.dest = zang.Oscillator.Params {
                    .waveform = .Square,
                    .freq = pair.source.freq,
                    .colour = 0.5,
                };
            }
            self.osc.paintFromImpulses(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, [0][]f32{}, conv.getImpulses());
        }
        zang.zero(temps[1]);
        {
            var conv = zang.ParamsConverter(InnerParams, zang.Gate.Params).init();
            self.gate.paintFromImpulses(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, [0][]f32{}, conv.autoStructural(impulses));
        }
        zang.multiply(out, temps[0], temps[1]);
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    iq: zang.Notes(Arpeggiator.Params).ImpulseQueue,
    current_params: Arpeggiator.Params,
    arpeggiator: zang.Triggerable(Arpeggiator),

    pub fn init() MainModule {
        return MainModule {
            .iq = zang.Notes(Arpeggiator.Params).ImpulseQueue.init(),
            .current_params = Arpeggiator.Params {
                .note_held = [1]bool{false} ** common.key_bindings.len,
            },
            .arpeggiator = zang.initTriggerable(Arpeggiator.init()),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];

        zang.zero(out);

        const impulses = self.iq.consume();

        self.arpeggiator.paintFromImpulses(sample_rate, [1][]f32{out}, [0][]f32{}, [2][]f32{tmp0, tmp1}, impulses);

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
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
