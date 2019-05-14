const std = @import("std");
const zang = @import("zang");
const f = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");
const PMOscInstrument = @import("modules.zig").PMOscInstrument;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 4096;

pub const DESCRIPTION =
    c\\example_song
    c\\
    c\\Plays a canned melody (the first few
    c\\bars of Bach's Toccata in D Minor).
    c\\
    c\\This example is not interactive.
;

const A4 = 440.0;

const MyNoteParams = PMOscInstrument.Params;
const MyNotes = zang.Notes(MyNoteParams);

const Note = common.Note;
const track1Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A4, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs4, .note_on = true }, .dur = 8 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D4, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D4, .note_on = false }, .dur = 4 },

    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A3, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E3, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F3, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs3, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = false }, .dur = 4 },

    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A2, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs2, .note_on = true }, .dur = 8 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D2, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D2, .note_on = false }, .dur = 2 },

    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D1, .note_on = true }, .dur = 128 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D1, .note_on = false }, .dur = 0 },
};
const track2Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A5, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs5, .note_on = true }, .dur = 8 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D5, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D5, .note_on = false }, .dur = 4 },

    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A4, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E4, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F4, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs4, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D4, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D4, .note_on = false }, .dur = 4 },

    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A3, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs3, .note_on = true }, .dur = 8 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = false }, .dur = 2 },
};
const ofs = 130;
const A = 6;
const B = 6;
const C = 5;
const D = 4;
const E = 4;
const track3Delay = ofs;
const track3Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs2, .note_on = true }, .dur = A + B + C + D + E + 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D2, .note_on = true }, .dur = 14 + (14 + 30) },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D2, .note_on = false }, .dur = 0 },
};
const track4Delay = ofs + A;
const track4Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E2, .note_on = true }, .dur = B + C + D + E + 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E2, .note_on = false }, .dur = 0 },
};
const track5Delay = ofs + A + B;
const track5Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G2, .note_on = true }, .dur = C + D + E + 30 + (14) },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E2, .note_on = true }, .dur = 14 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Fs2, .note_on = true }, .dur = 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Fs2, .note_on = false }, .dur = 0 },
};
const track6Delay = ofs + A + B + C;
const track6Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Bb2, .note_on = true }, .dur = D + E + 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A2, .note_on = true }, .dur = 14 + (14 + 30) },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A2, .note_on = false }, .dur = 0 },
};
const track7Delay = ofs + A + B + C + D;
const track7Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs3, .note_on = true }, .dur = E + 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs3, .note_on = false }, .dur = 0 },
};
const track8Delay = ofs + A + B + C + D + E;
const track8Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E3, .note_on = true }, .dur = 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = true }, .dur = 14 + (14 + 30) },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = false }, .dur = 0 },
};

const NUM_TRACKS = 8;
const NOTE_DURATION = 0.08;

const tracks = [NUM_TRACKS][]const MyNotes.SongNote {
    common.compileSong(MyNoteParams, track1Init.len, track1Init, NOTE_DURATION, 0.0),
    common.compileSong(MyNoteParams, track2Init.len, track2Init, NOTE_DURATION, 0.0),
    common.compileSong(MyNoteParams, track3Init.len, track3Init, NOTE_DURATION, track3Delay),
    common.compileSong(MyNoteParams, track4Init.len, track4Init, NOTE_DURATION, track4Delay),
    common.compileSong(MyNoteParams, track5Init.len, track5Init, NOTE_DURATION, track5Delay),
    common.compileSong(MyNoteParams, track6Init.len, track6Init, NOTE_DURATION, track6Delay),
    common.compileSong(MyNoteParams, track7Init.len, track7Init, NOTE_DURATION, track7Delay),
    common.compileSong(MyNoteParams, track8Init.len, track8Init, NOTE_DURATION, track8Delay),
};

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 4;

    instruments: [NUM_TRACKS]zang.Triggerable(PMOscInstrument),
    trackers: [NUM_TRACKS]MyNotes.NoteTracker,

    pub fn init() MainModule {
        var mod: MainModule = undefined;

        var i: usize = 0; while (i < NUM_TRACKS) : (i += 1) {
            mod.instruments[i] = zang.initTriggerable(PMOscInstrument.init(0.15));
            mod.trackers[i] = MyNotes.NoteTracker.init(tracks[i]);
        }

        return mod;
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        var i: usize = 0; while (i < NUM_TRACKS) : (i += 1) {
            const impulses = self.trackers[i].consume(sample_rate, outputs[0].len);
            self.instruments[i].paintFromImpulses(sample_rate, outputs, temps, impulses);
        }
    }
};
