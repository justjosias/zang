const std = @import("std");

// impulses are used both for songs and for dynamically created sounds.
// basically they are something scheduled. (in the case of dynamic sounds,
// they are scheduled for the immediate future)
pub const Impulse = struct {
    id: usize, // simple autoincrement
    frame: usize, // frames (e.g. 44100 for one second in)
    freq: ?f32, // if null, this is a "note off" event
};

pub const NoteSpanNote = struct {
    id: usize,
    freq: f32,
};

pub const NoteSpan = struct {
    start: usize,
    end: usize,
    note: ?NoteSpanNote, // null if it's a silent gap
};

// TODO - optimize this for songs. probably make a state object to help
// remember the last used note? or a lookup table into the song or something...
pub fn getNextNoteSpan(
    impulses: []const Impulse,
    frame_index: usize,
    dest_start: usize,
    dest_end: usize,
) NoteSpan {
    std.debug.assert(dest_start < dest_end);

    for (impulses) |impulse, i| {
        const start_pos = impulse.frame;

        if (start_pos >= frame_index + dest_end) {
            // this impulse (and all after it, since they're in chronological order)
            // starts after the end of the buffer
            break;
        }

        // this span ends at the start of the next impulse (if one exists), or the
        // end of the buffer, whichever comes first
        const end_pos =
            if (i < impulses.len - 1)
                std.math.min(frame_index + dest_end, impulses[i + 1].frame)
            else
                frame_index + dest_end;

        if (end_pos <= frame_index + dest_start) {
            // impulse is entirely in the past. skip it
            continue;
        }

        const note_start_clipped =
            if (start_pos > frame_index + dest_start)
                start_pos - frame_index
            else
                dest_start;

        if (note_start_clipped > dest_start) {
            // gap before the note begins
            return NoteSpan{
                .start = dest_start,
                .end = note_start_clipped,
                .note = null,
            };
        }

        const note_end = end_pos - frame_index;
        const note_end_clipped =
            if (note_end > dest_end)
                dest_end
            else
                note_end;

        return NoteSpan{
            .start = note_start_clipped,
            .end = note_end_clipped,
            .note =
                if (impulse.freq) |freq|
                    NoteSpanNote{
                        .id = impulse.id,
                        .freq = freq,
                    }
                else
                    null,
        };
    }

    std.debug.assert(dest_start < dest_end);

    return NoteSpan{
        .start = dest_start,
        .end = dest_end,
        .note = null,
    };
}
