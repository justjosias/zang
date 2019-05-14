const std = @import("std");

// TODO should/can this be parametrized by the ModuleType instead?
pub fn Notes(comptime NoteParamsType: type) type {
    return struct {
        pub const Impulse = struct {
            frame: i32, // frames (e.g. 44100 for one second in) FIXME - why is this signed
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

        pub const ImpulseQueue = struct {
            array: [32]Impulse,
            length: usize,
            next_id: usize,

            pub fn init() ImpulseQueue {
                return ImpulseQueue {
                    .array = undefined,
                    .length = 0,
                    .next_id = 1,
                };
            }

            // return impulses and advance state.
            // make sure to use the returned impulse list before pushing more stuff
            pub fn consume(self: *ImpulseQueue) ?*const Impulse {
                const impulses = if (self.length > 0) &self.array[0] else null;

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
                self.array[self.length] = Impulse {
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
            count: usize,
            dyn_tracker: DynamicNoteTracker,

            pub fn init(song: []const SongNote) NoteTracker {
                return NoteTracker {
                    .song = song,
                    .next_song_note = 0,
                    .t = 0.0,
                    .impulse_array = undefined,
                    .count = undefined,
                    .dyn_tracker = DynamicNoteTracker.init(),
                };
            }

            pub fn reset(self: *NoteTracker) void {
                self.next_song_note = 0;
                self.t = 0.0;
                self.dyn_tracker.reset();
            }

            // return impulses for notes that fall within the upcoming buffer frame
            pub fn begin(self: *NoteTracker, sample_rate: f32, out_len: usize) []Impulse {
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
                self.count = count;

                return self.impulse_array[0..count];
            }

            // these methods were split so the caller has an opportunity to
            // alter the impulses (e.g. change the note frequencies)
            pub fn finish(self: *NoteTracker) ?*const Impulse {
                const head = if (self.count > 0) &self.impulse_array[0] else null;

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