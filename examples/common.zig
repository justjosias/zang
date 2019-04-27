const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet").NoteFrequencies(440.0);
const c = @import("common/sdl.zig");

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

pub fn freqForKey(key: i32) ?f32 {
    const f = note_frequencies;

    return switch (key) {
        c.SDLK_a => f.C4,
        c.SDLK_w => f.Cs4,
        c.SDLK_s => f.D4,
        c.SDLK_e => f.Ds4,
        c.SDLK_d => f.E4,
        c.SDLK_f => f.F4,
        c.SDLK_t => f.Fs4,
        c.SDLK_g => f.G4,
        c.SDLK_y => f.Gs4,
        c.SDLK_h => f.A4,
        c.SDLK_u => f.As4,
        c.SDLK_j => f.B4,
        c.SDLK_k => f.C5,
        c.SDLK_o => f.Cs5,
        c.SDLK_l => f.D5,
        c.SDLK_p => f.Ds5,
        c.SDLK_SEMICOLON => f.E5,
        c.SDLK_QUOTE => f.F5,
        else => null,
    };
}
