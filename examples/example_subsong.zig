// in this example a little melody plays every time you hit a key
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

const A4 = 440.0;

const InnerInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct { freq: f32, note_on: bool };

    osc: zang.Oscillator,
    env: zang.Envelope,

    fn init() InnerInstrument {
        return InnerInstrument {
            .osc = zang.Oscillator.init(),
            .env = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 0.15,
            }),
        };
    }

    fn reset(self: *InnerInstrument) void {
        self.osc.reset();
        self.env.reset();
    }

    fn paint(self: *InnerInstrument, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        zang.zero(temps[0]);
        self.osc.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Oscillator.Params {
            .waveform = .Sawtooth,
            .freq = zang.constant(params.freq),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });
        zang.zero(temps[1]);
        self.env.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Envelope.Params {
            .note_on = params.note_on,
        });
        zang.multiply(outputs[0], temps[0], temps[1]);
    }
};

// an example of a custom "module"
const SubtrackPlayer = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct { freq: f32, note_on: bool };

    pub const BaseFrequency = A4 * note_frequencies.C4;

    tracker: zang.Notes(InnerInstrument.Params).NoteTracker,
    instr: zang.Triggerable(InnerInstrument),

    fn init() SubtrackPlayer {
        const SongNote = zang.Notes(InnerInstrument.Params).SongNote;
        const f = note_frequencies;

        return SubtrackPlayer {
            .tracker = zang.Notes(InnerInstrument.Params).NoteTracker.init([]SongNote {
                SongNote { .t = 0.0, .params = InnerInstrument.Params { .freq = A4 * f.C4, .note_on = true }},
                SongNote { .t = 0.1, .params = InnerInstrument.Params { .freq = A4 * f.Ab3, .note_on = true }},
                SongNote { .t = 0.2, .params = InnerInstrument.Params { .freq = A4 * f.G3, .note_on = true }},
                SongNote { .t = 0.3, .params = InnerInstrument.Params { .freq = A4 * f.Eb3, .note_on = true }},
                SongNote { .t = 0.4, .params = InnerInstrument.Params { .freq = A4 * f.C3, .note_on = true }},
                SongNote { .t = 0.5, .params = InnerInstrument.Params { .freq = A4 * f.C3, .note_on = false }},
            }),
            .instr = zang.initTriggerable(InnerInstrument.init()),
        };
    }

    fn reset(self: *SubtrackPlayer) void {
        self.tracker.reset();
        self.instr.reset();
    }

    fn paint(self: *SubtrackPlayer, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        for (self.tracker.begin(sample_rate, outputs[0].len)) |*impulse| {
            impulse.note.params.freq *= params.freq / BaseFrequency;
        }
        self.instr.paintFromImpulses(sample_rate, outputs, temps, self.tracker.finish());
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

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        self.subtrack_player.paintFromImpulses(sample_rate, outputs, temps, self.iq.consume());
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, SubtrackPlayer.Params { .freq = A4 * rel_freq, .note_on = down });
            }
        }
    }
};
