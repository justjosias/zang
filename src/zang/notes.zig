const std = @import("std");

// TODO should/can this be parametrized by the ModuleType instead?
pub fn Notes(comptime NoteParamsType: type) type {
    return struct {
        pub const Impulse = struct {
            frame: i32, // frames (e.g. 44100 for one second in) FIXME - why is this signed
            note: NoteSpanNote,
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
            pub fn consume(self: *ImpulseQueue) []const Impulse {
                const impulses = self.array[0..self.length];

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
                };
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

            pub fn init(song: []const SongNote) NoteTracker {
                return NoteTracker {
                    .song = song,
                    .next_song_note = 0,
                    .t = 0.0,
                    .impulse_array = undefined,
                    .count = undefined,
                };
            }

            pub fn reset(self: *NoteTracker) void {
                self.next_song_note = 0;
                self.t = 0.0;
            }

            // return impulses for notes that fall within the upcoming buffer frame.
            // note: the caller is free to mutate the impulses (e.g. change note frequencies)
            // before making use of them
            pub fn consume(self: *NoteTracker, sample_rate: f32, out_len: usize) []Impulse {
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
                        };
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
        };
    };
}

fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}

fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}