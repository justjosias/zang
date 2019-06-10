const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const c = @import("common/c.zig");

pub fn Note(comptime NoteParamsType: type) type {
    return struct {
        value: NoteParamsType,
        dur: usize,
    };
}

pub fn compileSong(
    comptime NoteParamsType: type,
    comptime len: usize,
    notes: [len]Note(NoteParamsType),
    note_duration: f32,
    initial_delay: usize,
) [len]zang.Notes(NoteParamsType).SongNote {
    var song_notes: [len]zang.Notes(NoteParamsType).SongNote = undefined;

    var pos = @intToFloat(f32, initial_delay) * note_duration;
    var i: usize = 0;

    for (notes) |note| {
        song_notes[i] = zang.Notes(NoteParamsType).SongNote {
            .t = pos,
            .params = note.value,
        };
        i += 1;
        pos += @intToFloat(f32, note.dur) * note_duration;
    }

    return song_notes;
}

pub const KeyBinding = struct {
    row: u1,
    key: i32,
    rel_freq: f32,
};

// note: arpeggiator will cycle in this order, so i've arranged it from lowest
// frequency to highest
pub const key_bindings = [_]KeyBinding {
    // bottom two rows is one octave
    KeyBinding { .row = 0, .rel_freq = note_frequencies.As2, .key = c.SDLK_CAPSLOCK },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.B2,  .key = c.SDLK_LSHIFT },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.C3,  .key = c.SDLK_z },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.Cs3, .key = c.SDLK_s },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.D3,  .key = c.SDLK_x },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.Ds3, .key = c.SDLK_d },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.E3,  .key = c.SDLK_c },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.F3,  .key = c.SDLK_v },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.Fs3, .key = c.SDLK_g },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.G3,  .key = c.SDLK_b },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.Gs3, .key = c.SDLK_h },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.A3,  .key = c.SDLK_n },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.As3, .key = c.SDLK_j },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.B3,  .key = c.SDLK_m },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.C4,  .key = c.SDLK_COMMA },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.Cs4, .key = c.SDLK_l },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.D4,  .key = c.SDLK_PERIOD },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.Ds4, .key = c.SDLK_SEMICOLON },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.E4,  .key = c.SDLK_SLASH },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.F4,  .key = c.SDLK_RSHIFT },
    KeyBinding { .row = 0, .rel_freq = note_frequencies.Fs4, .key = c.SDLK_RETURN },
    // top two rows is one octave up (with fair amount of overlap)
    KeyBinding { .row = 1, .rel_freq = note_frequencies.As3, .key = c.SDLK_BACKQUOTE },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.B3,  .key = c.SDLK_TAB },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.C4,  .key = c.SDLK_q },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.Cs4, .key = c.SDLK_2 },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.D4,  .key = c.SDLK_w },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.Ds4, .key = c.SDLK_3 },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.E4,  .key = c.SDLK_e },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.F4,  .key = c.SDLK_r },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.Fs4, .key = c.SDLK_5 },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.G4,  .key = c.SDLK_t },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.Gs4, .key = c.SDLK_6 },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.A4,  .key = c.SDLK_y },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.As4, .key = c.SDLK_7 },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.B4,  .key = c.SDLK_u },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.C5,  .key = c.SDLK_i },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.Cs5, .key = c.SDLK_9 },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.D5,  .key = c.SDLK_o },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.Ds5, .key = c.SDLK_0 },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.E5,  .key = c.SDLK_p },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.F5,  .key = c.SDLK_LEFTBRACKET },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.Fs5, .key = c.SDLK_EQUALS },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.G5,  .key = c.SDLK_RIGHTBRACKET },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.Gs5, .key = c.SDLK_BACKSPACE },
    KeyBinding { .row = 1, .rel_freq = note_frequencies.A5,  .key = c.SDLK_BACKSLASH },
};

pub fn getKeyRelFreq(key: i32) ?f32 {
    for (key_bindings) |kb| {
        if (kb.key == key) {
            return kb.rel_freq;
        }
    }
    return null;
}

pub fn getKeyRelFreqFromRow(row: u1, key: i32) ?f32 {
    for (key_bindings) |kb| {
        if (kb.row == row and kb.key == key) {
            return kb.rel_freq;
        }
    }
    return null;
}
