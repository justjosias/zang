const std = @import("std");
const zang = @import("zang");

pub const Note = struct {
    freq: ?f32, // null for silence
    dur: usize,
};

pub fn compileSong(
    comptime len: usize,
    notes: [len]Note,
    note_duration: f32,
) [len + 1]zang.SongNote {
    var song_notes: [len + 1]zang.SongNote = undefined;

    var pos: f32 = 0.0;
    var i: usize = 0;

    for (notes) |note| {
        song_notes[i] = zang.SongNote {
            .t = pos,
            .freq = note.freq,
        };
        i += 1;
        pos += @intToFloat(f32, note.dur) * note_duration;
    }

    // final note off event
    song_notes[i] = zang.SongNote {
        .t = pos,
        .freq = null,
    };
    i += 1;

    std.debug.assert(i == len + 1);

    return song_notes;
}

pub const KeyEvent = struct {
    iq: *zang.ImpulseQueue,
    freq: ?f32,
};
