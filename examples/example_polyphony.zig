// this a "brute force" approach to polyphony... every possible note gets its
// own voice that is always running. well, it works

const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet").NoteFrequencies(220.0);
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

const NUM_NOTES: usize = 18;
const key_freqs = [NUM_NOTES]f32 {
    note_frequencies.C4,
    note_frequencies.Cs4,
    note_frequencies.D4,
    note_frequencies.Ds4,
    note_frequencies.E4,
    note_frequencies.F4,
    note_frequencies.Fs4,
    note_frequencies.G4,
    note_frequencies.Gs4,
    note_frequencies.A4,
    note_frequencies.As4,
    note_frequencies.B4,
    note_frequencies.C5,
    note_frequencies.Cs5,
    note_frequencies.D5,
    note_frequencies.Ds5,
    note_frequencies.E5,
    note_frequencies.F5,
};

pub const MyNoteParams = Polyphony.Params;
pub const MyNotes = zang.Notes(MyNoteParams);

const Polyphony = struct {
    pub const NumOutputs = 1;
    pub const NumInputs = 0;
    pub const NumTemps = 2;
    pub const Params = struct {
        note_held: [NUM_NOTES]bool,
    };
    pub const InnerParams = struct {
        freq: f32,
        note_on: bool,
    };

    const Voice = struct {
        down: bool,
        iq: zang.Notes(InnerParams).ImpulseQueue,
        osc: zang.Triggerable(zang.Oscillator),
        envelope: zang.Triggerable(zang.Envelope),
    };

    voices: [NUM_NOTES]Voice,

    fn init() Polyphony {
        var self = Polyphony {
            .voices = undefined,
        };
        var i: usize = 0; while (i < NUM_NOTES) : (i += 1) {
            self.voices[i] = Voice {
                .down = false,
                .iq = zang.Notes(InnerParams).ImpulseQueue.init(),
                .osc = zang.initTriggerable(zang.Oscillator.init(.Square)),
                .envelope = zang.initTriggerable(zang.Envelope.init(zang.EnvParams {
                    .attack_duration = 0.01,
                    .decay_duration = 0.1,
                    .sustain_volume = 0.8,
                    .release_duration = 0.5,
                })),
            };
        }
        return self;
    }

    fn reset(self: *Polyphony) void {}

    fn paintSpan(self: *Polyphony, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const out = outputs[0];

        var i: usize = 0; while (i < NUM_NOTES) : (i += 1) {
            if (params.note_held[i] != self.voices[i].down) {
                self.voices[i].iq.push(0, InnerParams {
                    .freq = key_freqs[i],
                    .note_on = params.note_held[i],
                });
                self.voices[i].down = params.note_held[i];
            }
        }

        for (self.voices) |*voice| {
            const impulses = voice.iq.consume();

            zang.zero(temps[0]);
            {
                var conv = zang.ParamsConverter(InnerParams, zang.Oscillator.Params).init();
                for (conv.getPairs(impulses)) |*pair| {
                    pair.dest = zang.Oscillator.Params {
                        .freq = pair.source.freq,
                    };
                }
                voice.osc.paintFromImpulses(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, [0][]f32{}, conv.getImpulses());
            }
            zang.zero(temps[1]);
            {
                var conv = zang.ParamsConverter(InnerParams, zang.Envelope.Params).init();
                voice.envelope.paintFromImpulses(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, [0][]f32{}, conv.autoStructural(impulses));
            }
            zang.multiply(out, temps[0], temps[1]);
        }
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    iq: MyNotes.ImpulseQueue,
    current_params: MyNoteParams,
    polyphony: zang.Triggerable(Polyphony),

    pub fn init() MainModule {
        return MainModule{
            .iq = MyNotes.ImpulseQueue.init(),
            .current_params = MyNoteParams {
                .note_held = [1]bool{false} ** NUM_NOTES,
            },
            .polyphony = zang.initTriggerable(Polyphony.init()),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];

        zang.zero(out);

        const impulses = self.iq.consume();

        self.polyphony.paintFromImpulses(sample_rate, [1][]f32{out}, [0][]f32{}, [2][]f32{tmp0, tmp1}, impulses);

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, out_iq: **MyNotes.ImpulseQueue, out_params: *MyNoteParams) bool {
        const f = note_frequencies;

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
            c.SDLK_o => u5(13),
            c.SDLK_l => u5(14),
            c.SDLK_p => u5(15),
            c.SDLK_SEMICOLON => u5(16),
            c.SDLK_QUOTE => u5(17),
            else => null,
        }) |key_index| {
            self.current_params.note_held[key_index] = down;

            out_iq.* = &self.iq;
            out_params.* = self.current_params;
            return true;
        }

        return false;
    }
};
