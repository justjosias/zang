const std = @import("std");
const Notes = @import("notes.zig").Notes;

// convenience function
pub fn initTriggerable(module: var) Triggerable(@typeOf(module)) {
    return Triggerable(@typeOf(module)).init(module);
}

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

// TODO - reset method could be replaced by an argument to the paint method,
// should i do this?

// Triggerable: encapsulates a module, allowing it to be played from impulses.
// exposes the paintFromImpulses method (the module's paint method should
// not be used when using Triggerable).
// this tracks the last playing note in order to be able to detect
// a transition to a new note (upon which the module needs to be
// reset).
// it does NOT insert a span for a note started in a previous frame -
// that's expected to be already present in the `impulses` argument to
// `paintFromImpulses`. DynamicNodeTracker (and ImpulseQueue which uses
// it) do that.
// so, both Triggerable and DynamicNodeTracker are tracking the last
// playing note, but they're doing so for different reasons.
pub fn Triggerable(comptime ModuleType: type) type {
    const NoteSpanNote = Notes(ModuleType.Params).NoteSpanNote;
    const Impulse = Notes(ModuleType.Params).Impulse;

    const NoteSpan = struct {
        start: usize,
        end: usize,
        note: ?NoteSpanNote,
    };

    return struct {
        module: ModuleType,
        note: ?NoteSpanNote,

        pub fn init(module: ModuleType) @This() {
            return @This() {
                .module = module,
                .note = null,
            };
        }

        pub fn reset(self: *@This()) void {
            self.module.reset();
            self.note = null;
        }

        pub fn paintFromImpulses(
            self: *@This(),
            sample_rate: f32,
            output_bufs: [ModuleType.NumOutputs][]f32,
            temp_bufs: [ModuleType.NumTemps][]f32,
            impulses: []const Impulse,
        ) void {
            std.debug.assert(ModuleType.NumOutputs > 0);
            const buf_len = output_bufs[0].len;
            for (output_bufs) |buf| {
                std.debug.assert(buf.len == buf_len);
            }
            for (temp_bufs) |buf| {
                std.debug.assert(buf.len == buf_len);
            }

            var start: usize = 0;

            while (start < buf_len) {
                const note_span = getNextNoteSpan(self.note, impulses, start, buf_len);

                std.debug.assert(note_span.start == start);
                std.debug.assert(note_span.end > start);
                std.debug.assert(note_span.end <= buf_len);

                var output_spans: [ModuleType.NumOutputs][]f32 = undefined;
                comptime var ci: usize = 0;
                comptime while (ci < ModuleType.NumOutputs) : (ci += 1) {
                    output_spans[ci] = output_bufs[ci][note_span.start .. note_span.end];
                };
                var temp_spans: [ModuleType.NumTemps][]f32 = undefined;
                ci = 0;
                comptime while (ci < ModuleType.NumTemps) : (ci += 1) {
                    temp_spans[ci] = temp_bufs[ci][note_span.start .. note_span.end];
                };

                // if note_span.note is null, the first note hasn't started yet
                // (there is no way to go back to null once things start playing)
                if (note_span.note) |note| {
                    if (if (self.note) |self_note| (note.id != self_note.id) else true) {
                        self.note = note;

                        var should_reset = true;

                        // FIXME - this is a total hack... how else to do it?
                        inline for (@typeInfo(ModuleType.Params).Struct.fields) |field| {
                            if (comptime std.mem.eql(u8, field.name, "note_on")) {
                                if (!note.params.note_on) {
                                    should_reset = false;
                                }
                            }
                        }

                        if (should_reset) {
                            self.module.reset();
                        }
                    }

                    var params = note.params;

                    // for any param that is a []f32, pass along only the subslice for this note span.
                    // ditto for ConstantOrBuffer params that are Buffers
                    inline for (@typeInfo(ModuleType.Params).Struct.fields) |field| {
                        if (@typeId(field.field_type) == .Pointer and
                            @typeInfo(field.field_type).Pointer.size == .Slice and
                            @typeInfo(field.field_type).Pointer.child == f32) {
                            const slice = @field(params, field.name);
                            std.debug.assert(slice.len == buf_len);
                            @field(params, field.name) = slice[note_span.start .. note_span.end];
                        } else if (field.field_type == ConstantOrBuffer) {
                            switch (@field(params, field.name)) {
                                .Constant => {},
                                .Buffer => |slice| {
                                    std.debug.assert(slice.len == buf_len);
                                    @field(params, field.name) = ConstantOrBuffer {
                                        .Buffer = slice[note_span.start .. note_span.end],
                                    };
                                },
                            }
                        }
                    }

                    self.module.paint(sample_rate, output_spans, temp_spans, params);
                }

                start = note_span.end;
            }
        }

        fn getNextNoteSpan(current_note: ?NoteSpanNote, impulses: []const Impulse, dest_start_: usize, dest_end_: usize) NoteSpan {
            std.debug.assert(dest_start_ < dest_end_);

            const dest_start = @intCast(i32, dest_start_);
            const dest_end = @intCast(i32, dest_end_);

            if (dest_start_ == 0) {
                // check for currently playing note
                if (current_note) |note| {
                    if (impulses.len > 0) {
                        const first_impulse_frame = impulses[0].frame;
                        // play up until first impulse
                        if (first_impulse_frame == 0) {
                            // new impulse will override this from the beginning - continue
                        } else {
                            std.debug.assert(first_impulse_frame >= 0); // FIXME - remove.. frame should be unsigned
                            return NoteSpan {
                                .start = 0,
                                .end = @intCast(usize, min(i32, dest_end, first_impulse_frame)),
                                .note = note,
                            };
                        }
                    } else {
                        // no new impulses - play current note for the whole buffer
                        return NoteSpan {
                            .start = 0,
                            .end = dest_end_,
                            .note = note,
                        };
                    }
                }
            }

            for (impulses) |impulse, i| {
                const start_pos = impulse.frame;

                if (start_pos >= dest_end) {
                    // this impulse (and all after it, since they're in chronological order)
                    // starts after the end of the buffer
                    // TODO - crash? this shouldn't happen
                    break;
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

                // this span ends at the start of the next impulse (if one exists), or the
                // end of the buffer, whichever comes first
                const note_end_clipped =
                    if (i + 1 < impulses.len)
                        min(i32, dest_end, impulses[i + 1].frame)
                    else
                        dest_end;

                if (note_end_clipped <= dest_start) {
                    // impulse is entirely in the past. skip it
                    continue;
                }

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
    };
}

fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}
