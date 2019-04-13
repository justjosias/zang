const std = @import("std");

const note_span_mod = @import("note_span.zig");
const Impulse = note_span_mod.Impulse;
const getNextNoteSpan = note_span_mod.getNextNoteSpan;

// typical usage (not really a unit test...)
test "getNextNoteSpan" {
    const impulses = []Impulse{
        Impulse{ .id = 1, .frame = 5000, .freq = 440.0 },
        Impulse{ .id = 2, .frame = 7000, .freq = 550.0 },
        Impulse{ .id = 3, .frame = 9000, .freq = 660.0 },
        // TODO - add one at an exact mix frame boundary?
    };

    // first frame

    var note_span = getNextNoteSpan(
        impulses,
        0, // frame_index
        0, // dest_start
        4096, // dest_end
    );
    std.testing.expect(note_span.start == 0);
    std.testing.expect(note_span.end == 4096);
    std.testing.expect(note_span.note == null);

    // second frame

    note_span = getNextNoteSpan(
        impulses,
        4096, // frame_index
        0, // dest_start
        4096, // dest_end
    );
    std.testing.expect(note_span.start == 0);
    std.testing.expect(note_span.end == 5000 - 4096);
    std.testing.expect(note_span.note == null);

    note_span = getNextNoteSpan(
        impulses,
        4096, // frame_index,
        5000 - 4096, // dest_start
        4096, // dest_end
    );
    std.testing.expect(note_span.start == 5000 - 4096);
    std.testing.expect(note_span.end == 7000 - 4096);
    std.testing.expect(if (note_span.note) |note| note.id == 1 else false);
    std.testing.expect(if (note_span.note) |note| note.freq == 440.0 else false);

    note_span = getNextNoteSpan(
        impulses,
        4096, // frame_index
        7000 - 4096, // dest_start
        4096, // dest_end,
    );
    std.testing.expect(note_span.start == 7000 - 4096);
    std.testing.expect(note_span.end == 4096);
    std.testing.expect(if (note_span.note) |note| note.id == 2 else false);
    std.testing.expect(if (note_span.note) |note| note.freq == 550.0 else false);

    // third frame

    note_span = getNextNoteSpan(
        impulses,
        8192, // frame_index
        0, // dest_start
        4096, // dest_end
    );
    std.testing.expect(note_span.start == 0);
    std.testing.expect(note_span.end == 9000 - 8192);
    std.testing.expect(if (note_span.note) |note| note.id == 2 else false);
    std.testing.expect(if (note_span.note) |note| note.freq == 550.0 else false);

    note_span = getNextNoteSpan(
        impulses,
        8192, // frame_index
        9000 - 8192, // dest_start
        4096, // dest_end,
    );
    std.testing.expect(note_span.start == 9000 - 8192);
    std.testing.expect(note_span.end == 4096);
    std.testing.expect(if (note_span.note) |note| note.id == 3 else false);
    std.testing.expect(if (note_span.note) |note| note.freq == 660.0 else false);

    // fourth frame

    note_span = getNextNoteSpan(
        impulses,
        12288, // frame_index
        0, // dest_start
        4096, // dest_end
    );
    std.testing.expect(note_span.start == 0);
    std.testing.expect(note_span.end == 4096);
    std.testing.expect(if (note_span.note) |note| note.id == 3 else false);
    std.testing.expect(if (note_span.note) |note| note.freq == 660.0 else false);
}
