const std = @import("std");

pub const Impulse = struct {
    frame: usize, // frames (e.g. 44100 for one second in)
    note_id: usize,
};

pub fn Notes(comptime NoteParamsType: type) type {
    return struct {
        pub const ImpulsesAndParamses = struct {
            // these two slices will have the same length
            impulses: []const Impulse,
            paramses: []const NoteParamsType,
        };

        pub const SongNote = struct {
            params: NoteParamsType,
            t: f32,
        };

        pub const ImpulseQueue = struct {
            impulses_array: [32]Impulse,
            paramses_array: [32]NoteParamsType,
            length: usize,
            next_id: usize,

            pub fn init() ImpulseQueue {
                return ImpulseQueue {
                    .impulses_array = undefined,
                    .paramses_array = undefined,
                    .length = 0,
                    .next_id = 1,
                };
            }

            // return impulses and advance state.
            // make sure to use the returned impulse list before pushing more stuff
            // FIXME shuldn't this take in a span?
            // although it's probably fine now because we're never using an impulse queue
            // within something...
            pub fn consume(self: *ImpulseQueue) ImpulsesAndParamses {
                defer self.length = 0;

                return ImpulsesAndParamses {
                    .impulses = self.impulses_array[0..self.length],
                    .paramses = self.paramses_array[0..self.length],
                };
            }

            pub fn push(self: *ImpulseQueue, impulse_frame: usize, params: NoteParamsType) void {
                const actual_impulse_frame = blk: {
                    if (self.length > 0) {
                        const last_impulse_frame = self.impulses_array[self.length - 1].frame;

                        // if the new impulse would be at the same time or earlier than
                        // the previous one, have it replace the previous one
                        // FIXME - should i not bother with this here, and just make sure
                        // Triggerable handles it correctly?
                        if (impulse_frame <= last_impulse_frame) {
                            self.length -= 1;
                            break :blk last_impulse_frame;
                        }
                    }

                    break :blk impulse_frame;
                };

                const note_id = self.next_id;
                self.next_id += 1;

                if (self.length >= self.impulses_array.len) {
                    std.debug.warn("ImpulseQueue: no more slots\n");
                    return;
                }
                self.impulses_array[self.length] = Impulse {
                    .frame = actual_impulse_frame,
                    .note_id = note_id,
                };
                self.paramses_array[self.length] = params;
                self.length += 1;
            }
        };

        // follow a canned melody, creating impulses from it, one mix buffer at a time
        pub const NoteTracker = struct {
            song: []const SongNote,
            next_song_note: usize,
            t: f32,
            impulses_array: [32]Impulse, // internal storage
            paramses_array: [32]NoteParamsType,

            pub fn init(song: []const SongNote) NoteTracker {
                return NoteTracker {
                    .song = song,
                    .next_song_note = 0,
                    .t = 0.0,
                    .impulses_array = undefined,
                    .paramses_array = undefined,
                };
            }

            pub fn reset(self: *NoteTracker) void {
                self.next_song_note = 0;
                self.t = 0.0;
            }

            // return impulses for notes that fall within the upcoming buffer frame.
            pub fn consume(self: *NoteTracker, sample_rate: f32, out_len: usize) ImpulsesAndParamses {
                var count: usize = 0;

                const buf_time = @intToFloat(f32, out_len) / sample_rate;
                const end_t = self.t + buf_time;

                for (self.song[self.next_song_note..]) |song_note| {
                    const note_t = song_note.t;
                    if (note_t < end_t) {
                        const f = (note_t - self.t) / buf_time; // 0 to 1
                        const rel_frame_index = min(usize, @floatToInt(usize, f * @intToFloat(f32, out_len)), out_len - 1);
                        // TODO - do something graceful-ish when count >= self.impulse_array.len
                        self.impulses_array[count] = Impulse {
                            .frame = rel_frame_index,
                            .note_id = self.next_song_note,
                        };
                        self.paramses_array[count] = song_note.params;
                        count += 1;
                        self.next_song_note += 1;
                    } else {
                        break;
                    }
                }

                self.t += buf_time;

                return ImpulsesAndParamses {
                    .impulses = self.impulses_array[0..count],
                    .paramses = self.paramses_array[0..count],
                };
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
