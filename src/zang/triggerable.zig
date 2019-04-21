const std = @import("std");
const Impulse = @import("types.zig").Impulse;
const NoteSpanNote = @import("types.zig").NoteSpanNote;

const NoteSpan = struct {
    start: usize,
    end: usize,
    note: ?NoteSpanNote, // null if it's a silent gap
};

// this object provides the method `paintFromImpulses` which will call into the
// module's `paint` method for each impulse.
// expects ModuleType to have:
// - NumTempBufs constant
// - paint method
// - reset method
// TODO - rename. the -able suffix makes it seem like a trait, which it's not
// (quite). maybe just `Trigger`?
// TODO - somehow generalize the note value. currently it's a frequency but you
// might want to use it for something else, like filter cutoff. maybe the
// module even has multiple paint methods?
pub fn Triggerable(comptime ModuleType: type) type {
    return struct {
        // this tracks the last playing note in order to be able to detect
        // a transition to a new note (upon which the module needs to be
        // reset).
        // it does NOT insert a span for a note started in a previous frame -
        // that's expected to be already present in the `impulses` argument to
        // `paintFromImpulses`. DynamicNodeTracker (and ImpulseQueue which uses
        // it) do that.
        // so, both Triggerable and DynamicNodeTracker are tracking the last
        // playing note, but they're doing so for different reasons.
        note: ?NoteSpanNote,

        pub fn init() @This() {
            return @This() {
                .note = null,
            };
        }

        pub fn paintFromImpulses(
            self: *@This(),
            module: *ModuleType,
            sample_rate: f32,
            out: []f32,
            impulses: ?*const Impulse,
            tmp_bufs: [ModuleType.NumTempBufs][]f32,
        ) void {
            var i: usize = 0;
            while (i < ModuleType.NumTempBufs) : (i += 1) {
                std.debug.assert(out.len == tmp_bufs[i].len);
            }

            var start: usize = 0;

            while (start < out.len) {
                const note_span = getNextNoteSpan(impulses, start, out.len);

                std.debug.assert(note_span.start == start);
                std.debug.assert(note_span.end > start);
                std.debug.assert(note_span.end <= out.len);

                const buf_span = out[note_span.start .. note_span.end];
                var tmp_spans: [ModuleType.NumTempBufs][]f32 = undefined;
                comptime var ci: usize = 0;
                comptime while (ci < ModuleType.NumTempBufs) : (ci += 1) {
                    tmp_spans[ci] = tmp_bufs[ci][note_span.start .. note_span.end];
                };

                if (note_span.note) |note| {
                    if (if (self.note) |self_note| (note.id != self_note.id) else true) {
                        self.note = note;
                        module.reset();
                    }

                    module.paint(sample_rate, buf_span, true, note.freq, tmp_spans);
                } else {
                    // if there's no new note, keep playing the most recent
                    // note. if you want "note off" behaviour you'll have to
                    // implement it in the calling code (because suddenly
                    // cutting off audio at note-off is rarely what you
                    // actually want)
                    if (self.note) |self_note| {
                        module.paint(sample_rate, buf_span, false, self_note.freq, tmp_spans);
                    }
                }

                start = note_span.end;
            }
        }
    };
}

fn getNextNoteSpan(impulses: ?*const Impulse, dest_start_: usize, dest_end_: usize) NoteSpan {
    std.debug.assert(dest_start_ < dest_end_);

    const dest_start = @intCast(i32, dest_start_);
    const dest_end = @intCast(i32, dest_end_);

    var maybe_impulse = impulses;
    while (maybe_impulse) |impulse| : (maybe_impulse = impulse.next) {
        const start_pos = impulse.frame;

        if (start_pos >= dest_end) {
            // this impulse (and all after it, since they're in chronological order)
            // starts after the end of the buffer
            // TODO - crash? this shouldn't happen
            break;
        }

        // this span ends at the start of the next impulse (if one exists), or the
        // end of the buffer, whichever comes first
        const end_pos =
            if (impulse.next) |next_impulse|
                min(i32, dest_end, next_impulse.frame)
            else
                dest_end;

        if (end_pos <= dest_start) {
            // impulse is entirely in the past. skip it
            continue;
        }

        const note_start_clipped =
            if (start_pos > dest_start)
                start_pos
            else
                dest_start;

        if (note_start_clipped > dest_start) {
            // gap before the note begins
            return NoteSpan {
                .start = @intCast(usize, dest_start),
                .end = @intCast(usize, note_start_clipped),
                .note = null,
            };
        }

        const note_end = end_pos;
        const note_end_clipped =
            if (note_end > dest_end)
                dest_end
            else
                note_end;

        return NoteSpan {
            .start = @intCast(usize, note_start_clipped),
            .end = @intCast(usize, note_end_clipped),
            .note = impulse.note,
        };
    }

    std.debug.assert(dest_start < dest_end);

    return NoteSpan {
        .start = @intCast(usize, dest_start),
        .end = @intCast(usize, dest_end),
        .note = null,
    };
}

fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}
