const std = @import("std");

// TODO i think this file has logic to carry over frequency in note off events (not sure).
// that's been removed so maybe i can remove some code here?

pub fn Notes(comptime NoteParamsType: type) type {
    return struct {
        pub const Impulse = struct {
            frame: i32, // frames (e.g. 44100 for one second in)
            note: NoteSpanNote,
            next: ?*const Impulse,
        };

        pub const NoteSpanNote = struct {
            id: usize,
            params: NoteParamsType,
        };

        pub const SongNote = struct {
            params: NoteParamsType,
            t: f32,
        };

        const NoteSpan = struct {
            start: usize,
            end: usize,
            note: ?NoteSpanNote,
        };

        // this object provides the method `paintFromImpulses` which will call into the
        // module's `paint` method for each impulse.
        // expects ModuleType to have:
        // - NumTemps constant
        // - paint method
        // - reset method
        // TODO - reset method could be replaced by an argument to the paint method,
        // should i do this?
        pub fn Trigger(comptime ModuleType: type) type {
            return struct {
                // this tracks the last playing note in order to be able to detect
                // a transition to a new note (upon which the module needs to be
                // reset).
                // it does NOT insert a span for a note started in a previous frame -
                // that's expected to be already present in the `impulses` argument to
                // `paintFromImpulses`. DynamicNodeTracker (and ImpulseQueue which uses
                // it) do that.
                // so, both Trigger and DynamicNodeTracker are tracking the last
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
                    output_bufs: [ModuleType.NumOutputs][]f32,
                    input_bufs: [ModuleType.NumInputs][]f32,
                    temp_bufs: [ModuleType.NumTemps][]f32,
                    impulses: ?*const Impulse,
                ) void {
                    std.debug.assert(ModuleType.NumOutputs > 0);
                    const buf_len = output_bufs[0].len;
                    for (output_bufs) |buf| {
                        std.debug.assert(buf.len == buf_len);
                    }
                    for (input_bufs) |buf| {
                        std.debug.assert(buf.len == buf_len);
                    }
                    for (temp_bufs) |buf| {
                        std.debug.assert(buf.len == buf_len);
                    }

                    var start: usize = 0;

                    while (start < buf_len) {
                        const note_span = getNextNoteSpan(impulses, start, buf_len);

                        std.debug.assert(note_span.start == start);
                        std.debug.assert(note_span.end > start);
                        std.debug.assert(note_span.end <= buf_len);

                        var output_spans: [ModuleType.NumOutputs][]f32 = undefined;
                        comptime var ci: usize = 0;
                        comptime while (ci < ModuleType.NumOutputs) : (ci += 1) {
                            output_spans[ci] = output_bufs[ci][note_span.start .. note_span.end];
                        };
                        var input_spans: [ModuleType.NumInputs][]f32 = undefined;
                        ci = 0;
                        comptime while (ci < ModuleType.NumInputs) : (ci += 1) {
                            input_spans[ci] = input_bufs[ci][note_span.start .. note_span.end];
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
                                inline for (@typeInfo(NoteParamsType).Struct.fields) |field| {
                                    if (comptime std.mem.eql(u8, field.name, "note_on")) {
                                        if (!note.params.note_on) {
                                            should_reset = false;
                                        }
                                    }
                                }

                                if (should_reset) {
                                    module.reset();
                                }
                            }

                            module.paintSpan(sample_rate, output_spans, input_spans, temp_spans, note.params);
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

        pub const ImpulseQueue = struct {
            array: [32]Impulse,
            length: usize,
            next_id: usize,
            dyn_tracker: DynamicNoteTracker,

            pub fn init() ImpulseQueue {
                return ImpulseQueue{
                    .array = undefined,
                    .length = 0,
                    .next_id = 1,
                    .dyn_tracker = DynamicNoteTracker.init(),
                };
            }

            // return impulses and advance state.
            // make sure to use the returned impulse list before pushing more stuff
            pub fn consume(self: *ImpulseQueue) ?*const Impulse {
                // the dyn_tracker will carry over an impulse that was started previously
                const impulses = self.dyn_tracker.getImpulses(if (self.length > 0) &self.array[0] else null);

                self.length = 0;

                return impulses;
            }

            pub fn push(self: *ImpulseQueue, impulse_frame_: usize, params: NoteParamsType) void {
                const impulse_frame = blk: {
                    const impulse_frame = @intCast(i32, impulse_frame_);

                    if (self.length > 0) {
                        const last_impulse_frame = self.array[self.length - 1].frame;

                        // if the new impulse would be at the same time or earlier than
                        // the previous one, have it replace the previous one
                        if (impulse_frame <= last_impulse_frame) {
                            self.length -= 1;
                            break :blk last_impulse_frame;
                        }
                    }

                    break :blk impulse_frame;
                };

                const note = blk: {
                    const id = self.next_id;
                    self.next_id += 1;

                    break :blk NoteSpanNote {
                        .id = id,
                        .params = params,
                    };
                };

                if (self.length >= self.array.len) {
                    std.debug.warn("ImpulseQueue: no more slots\n");
                    return;
                }
                self.array[self.length] = Impulse{
                    .frame = impulse_frame,
                    .note = note,
                    .next = null,
                };
                if (self.length > 0) {
                    self.array[self.length - 1].next = &self.array[self.length];
                }
                self.length += 1;
            }
        };

        // follow a canned melody, creating impulses from it, one mix buffer at a time
        pub const NoteTracker = struct {
            song: []const SongNote,
            next_song_note: usize,
            t: f32,
            impulse_array: [32]Impulse, // internal storage (TODO - should it be passed in instead?)
            dyn_tracker: DynamicNoteTracker,

            pub fn init(song: []const SongNote) NoteTracker {
                return NoteTracker {
                    .song = song,
                    .next_song_note = 0,
                    .t = 0.0,
                    .impulse_array = undefined,
                    .dyn_tracker = DynamicNoteTracker.init(),
                };
            }

            pub fn reset(self: *NoteTracker) void {
                self.next_song_note = 0;
                self.t = 0.0;
                self.dyn_tracker.reset();
            }

            // return impulses for notes that fall within the upcoming buffer frame
            pub fn getImpulses(self: *NoteTracker, sample_rate: f32, out_len: usize) ?*const Impulse {
                var count: usize = 0;

                const buf_time = @intToFloat(f32, out_len) / sample_rate;
                const end_t = self.t + buf_time;

                for (self.song[self.next_song_note..]) |song_note| {
                    const note_t = song_note.t;
                    if (note_t < end_t) {
                        const f = (note_t - self.t) / buf_time; // 0 to 1
                        const rel_frame_index = min(usize, @floatToInt(usize, f * @intToFloat(f32, out_len)), out_len - 1);
                        // TODO - do something graceful-ish when count >= self.impulse_array.len
                        self.impulse_array[count] = Impulse {
                            .frame = @intCast(i32, rel_frame_index),
                            .note = NoteSpanNote {
                                .id = self.next_song_note,
                                .params = song_note.params,
                            },
                            .next = null,
                        };
                        if (count > 0) {
                            self.impulse_array[count - 1].next = &self.impulse_array[count];
                        }
                        count += 1;
                        self.next_song_note += 1;
                    } else {
                        break;
                    }
                }

                self.t += buf_time;

                const head = if (count > 0) &self.impulse_array[0] else null;

                return self.dyn_tracker.getImpulses(head);
            }
        };

        // TODO - rename
        // all this does is remember the currently playing note, and push it to the
        // front of a list of impulses
        pub const DynamicNoteTracker = struct {
            // stored_prev: this just exists to keep memory in scope to store the return value of getImpulses
            stored_prev: Impulse,
            // next_prev: the last note that played in the previous buffer frame
            next_prev: ?NoteSpanNote,

            pub fn init() DynamicNoteTracker {
                return DynamicNoteTracker {
                    .stored_prev = undefined,
                    .next_prev = null,
                };
            }

            pub fn reset(self: *DynamicNoteTracker) void {
                self.next_prev = null;
            }

            // note: the returned list uses pointers to `source`, so when `source` goes
            // out of scope, consider the returned list to be freed
            pub fn getImpulses(self: *DynamicNoteTracker, source: ?*const Impulse) ?*const Impulse {
                var head = source;

                // if there's an old note playing and it's not overridden by a new note
                // at frame=0, push it to the front of the list
                if (self.next_prev) |prev| {
                    if (source == null or (if (source) |s| s.frame > 0 else false)) {
                        self.stored_prev = Impulse {
                            .frame = 0,
                            .note = prev,
                            .next = head,
                        };
                        head = &self.stored_prev;
                    }
                }

                // set new value of self.next_prev
                const maybe_last = blk: {
                    var maybe_impulse = source;
                    while (maybe_impulse) |impulse| : (maybe_impulse = impulse.next) {
                        if (impulse.next == null) {
                            break :blk impulse;
                        }
                    }
                    break :blk null;
                };

                if (maybe_last) |last| {
                    self.next_prev = last.note;
                }
                // otherwise, preserve the existing value of next_prev

                return head;
            }
        };
    };
}

fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}

fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}