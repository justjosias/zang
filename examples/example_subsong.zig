// TODO - maybe add an envelope effect at the outer level, to demonstrate that
// the note events are nesting correctly

const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_subsong
    c\\
    c\\Play with the keyboard - a little
    c\\melody is played with each keypress.
    c\\This demonstrates "notes within notes".
;

const A4 = 440.0;

const InnerInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    osc: zang.Oscillator,
    env: zang.Envelope,

    fn init() InnerInstrument {
        return InnerInstrument {
            .osc = zang.Oscillator.init(),
            .env = zang.Envelope.init(),
        };
    }

    fn reset(self: *InnerInstrument) void {
        self.osc.reset();
        self.env.reset();
    }

    fn paint(self: *InnerInstrument, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        zang.zero(temps[0]);
        self.osc.paint([1][]f32{temps[0]}, [0][]f32{}, zang.Oscillator.Params {
            .sample_rate = params.sample_rate,
            .waveform = .Sawtooth,
            .freq = zang.constant(params.freq),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });
        zang.zero(temps[1]);
        self.env.paint([1][]f32{temps[1]}, [0][]f32{}, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack_duration = 0.025,
            .decay_duration = 0.1,
            .sustain_volume = 0.5,
            .release_duration = 0.15,
            .note_on = params.note_on,
        });
        zang.multiply(outputs[0], temps[0], temps[1]);
    }
};

const MyNoteParams = struct {
    freq: f32,
    note_on: bool,
};

// an example of a custom "module"
const SubtrackPlayer = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    pub const BaseFrequency = A4 * note_frequencies.C4;

    tracker: zang.Notes(MyNoteParams).NoteTracker,
    instr: zang.Triggerable(InnerInstrument),

    fn init() SubtrackPlayer {
        const SongNote = zang.Notes(MyNoteParams).SongNote;
        const f = note_frequencies;

        return SubtrackPlayer {
            .tracker = zang.Notes(MyNoteParams).NoteTracker.init([]SongNote {
                SongNote { .t = 0.0, .params = MyNoteParams { .freq = A4 * f.C4, .note_on = true }},
                SongNote { .t = 0.1, .params = MyNoteParams { .freq = A4 * f.Ab3, .note_on = true }},
                SongNote { .t = 0.2, .params = MyNoteParams { .freq = A4 * f.G3, .note_on = true }},
                SongNote { .t = 0.3, .params = MyNoteParams { .freq = A4 * f.Eb3, .note_on = true }},
                SongNote { .t = 0.4, .params = MyNoteParams { .freq = A4 * f.C3, .note_on = true }},
                SongNote { .t = 0.5, .params = MyNoteParams { .freq = A4 * f.C3, .note_on = false }},
            }),
            .instr = zang.initTriggerable(InnerInstrument.init()),
        };
    }

    fn reset(self: *SubtrackPlayer) void {
        self.tracker.reset();
        self.instr.reset();
    }

    fn paint(self: *SubtrackPlayer, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        // create a new list of impulses combining multiple sources
        // FIXME - see https://github.com/dbandstra/zang/issues/18
        var impulses: [32]zang.Notes(InnerInstrument.Params).Impulse = undefined;
        var num_impulses: usize = 0;
        for (self.tracker.consume(params.sample_rate, outputs[0].len)) |impulse| {
            impulses[num_impulses] = zang.Notes(InnerInstrument.Params).Impulse {
                .frame = impulse.frame,
                .note = zang.Notes(InnerInstrument.Params).NoteSpanNote {
                    .id = impulse.note.id,
                    .params = InnerInstrument.Params {
                        .sample_rate = params.sample_rate,
                        .freq = impulse.note.params.freq * params.freq / BaseFrequency,
                        .note_on = impulse.note.params.note_on,
                    },
                },
            };
            num_impulses += 1;
        }
        self.instr.paintFromImpulses(outputs, temps, impulses);
    }
};

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;

    iq: zang.Notes(SubtrackPlayer.Params).ImpulseQueue,
    key: ?i32,
    subtrack_player: zang.Triggerable(SubtrackPlayer),

    pub fn init() MainModule {
        return MainModule {
            .iq = zang.Notes(SubtrackPlayer.Params).ImpulseQueue.init(),
            .key = null,
            .subtrack_player = zang.initTriggerable(SubtrackPlayer.init()),
        };
    }

    pub fn paint(self: *MainModule, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        self.subtrack_player.paintFromImpulses(outputs, temps, self.iq.consume());
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, SubtrackPlayer.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .freq = A4 * rel_freq,
                    .note_on = down,
                });
            }
        }
    }
};
