const Impulse = @import("notes.zig").Impulse;
const Notes = @import("notes.zig").Notes;
const Span = @import("basics.zig").Span;

pub const ConstantOrBuffer = union(enum) {
    Constant: f32,
    Buffer: []const f32,
};

pub fn constant(x: f32) ConstantOrBuffer {
    return ConstantOrBuffer { .Constant = x };
}

pub fn buffer(buf: []const f32) ConstantOrBuffer {
    return ConstantOrBuffer { .Buffer = buf };
}

pub fn Trigger(comptime ParamsType: type) type {
    const NoteSpanNote = struct {
        id: usize,
        params: ParamsType,
    };

    const NoteSpan = struct {
        start: usize,
        end: usize,
        note: ?NoteSpanNote,
    };

    return struct {
        note: ?NoteSpanNote,

        pub const Counter = struct {
            iap: Notes(ParamsType).ImpulsesAndParamses,
            impulse_index: usize,
            start: usize,
            end: usize,
        };

        pub const NewPaintReturnValue = struct {
            span: Span,
            params: ParamsType,
            note_id_changed: bool,
        };

        pub fn init() @This() {
            return @This() {
                .note = null,
            };
        }

        pub fn reset(self: *@This()) void {
            self.note = null;
        }

        pub fn counter(self: *@This(), span: Span, iap: Notes(ParamsType).ImpulsesAndParamses) Counter {
            return Counter {
                .iap = iap,
                .impulse_index = 0,
                .start = span.start,
                .end = span.end,
            };
        }

        pub fn next(self: *@This(), ctr: *Counter) ?NewPaintReturnValue {
            while (ctr.start < ctr.end) {
                const note_span = carryOver(ctr, self.note) orelse getNextNoteSpan(ctr, self.note);

                ctr.start = note_span.end;

                // if note_span.note is null, the first note hasn't started yet
                // (there is no way to go back to null once things start playing)
                if (note_span.note) |note| {
                    var note_id_changed = false;

                    if (if (self.note) |self_note| (note.id != self_note.id) else true) {
                        self.note = note;
                        note_id_changed = true;
                    }

                    return NewPaintReturnValue {
                        .span = Span {
                            .start = note_span.start,
                            .end = note_span.end,
                        },
                        .params = note.params,
                        .note_id_changed = note_id_changed,
                    };
                }
            }

            return null;
        }

        fn carryOver(ctr: *const Counter, current_note: ?NoteSpanNote) ?NoteSpan {
            // check for currently playing note
            if (current_note) |note| {
                if (ctr.impulse_index < ctr.iap.impulses.len) {
                    const next_impulse_frame = ctr.iap.impulses[ctr.impulse_index].frame;

                    if (next_impulse_frame > ctr.start) {
                        // next impulse starts later, so play the current note for now
                        return NoteSpan {
                            .start = ctr.start,
                            .end = min(usize, ctr.end, next_impulse_frame),
                            .note = note,
                        };
                    } else {
                        // next impulse starts now
                        return null;
                    }
                } else {
                    // no new impulses - play current note for the whole buffer
                    return NoteSpan {
                        .start = ctr.start,
                        .end = ctr.end,
                        .note = note,
                    };
                }
            } else {
                return null;
            }
        }

        fn getNextNoteSpan(ctr: *Counter, current_note: ?NoteSpanNote) NoteSpan {
            const impulses = ctr.iap.impulses[ctr.impulse_index..];
            const paramses = ctr.iap.paramses[ctr.impulse_index..];

            for (impulses) |impulse, i| {
                if (impulse.frame >= ctr.end) {
                    // this impulse (and all after it, since they're in chronological order)
                    // starts after the end of the buffer.
                    // this should never happen (you should never create an impulse at >=
                    // "mix_buffer_length")
                    break;
                }

                if (impulse.frame > ctr.start) {
                    // gap before the note begins
                    return NoteSpan {
                        .start = ctr.start,
                        .end = impulse.frame,
                        .note = null,
                    };
                }

                ctr.impulse_index += 1;

                // this span ends at the start of the next impulse (if one exists), or the
                // end of the buffer, whichever comes first
                const note_end_clipped =
                    if (i + 1 < impulses.len)
                        min(usize, ctr.end, impulses[i + 1].frame)
                    else
                        ctr.end;

                if (note_end_clipped <= ctr.start) {
                    // impulse is entirely in the past. skip it
                    continue;
                }

                return NoteSpan {
                    .start = ctr.start,
                    .end = note_end_clipped,
                    .note = NoteSpanNote {
                        .id = impulse.note_id,
                        .params = paramses[i],
                    },
                };
            }

            // no more impulses
            return NoteSpan {
                .start = ctr.start,
                .end = ctr.end,
                .note = null,
            };
        }
    };
}

fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}
