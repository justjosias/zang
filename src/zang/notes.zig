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
                    std.debug.warn("ImpulseQueue: no more slots\n"); // FIXME
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

        pub const SongNote = struct {
            params: NoteParamsType,
            t: f32,
            id: usize,
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
                        const rel_frame_index = std.math.min(@floatToInt(usize, f * @intToFloat(f32, out_len)), out_len - 1);
                        // TODO - do something graceful-ish when count >= self.impulse_array.len
                        self.impulses_array[count] = Impulse {
                            .frame = rel_frame_index,
                            .note_id = song_note.id,// self.next_song_note,
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

        pub fn PolyphonyDispatcher(comptime polyphony: usize) type {
            const SlotState = struct {
                note_id: usize,
                // polyphony only works when the ParamsType includes note_on.
                // we need this to be able to determine when to reuse slots
                note_on: bool,
            };

            return struct {
                slots: [polyphony]?SlotState,
                // TODO - i should be able to use a single array for each of these
                // because only 32 impulses can come in, only 32 impulses could come out...
                // or can i even reuse the storage of the NoteTracker?
                impulses_array: [polyphony][32]Impulse, // internal storage
                paramses_array: [polyphony][32]NoteParamsType,

                pub fn init() @This() {
                    return @This() {
                        .slots = [1]?SlotState{null} ** polyphony,
                        .impulses_array = undefined,
                        .paramses_array = undefined,
                    };
                }

                fn chooseSlot(self: *const @This(), note_id: usize) usize {
                    // first, try to reuse a slot that's already assigned to this note_id
                    for (self.slots) |maybe_slot, slot_index| {
                        if (maybe_slot) |slot| {
                            if (slot.note_id == note_id) {
                                return slot_index;
                            }
                        }
                    }
                    // otherwise pick the note-off slot with the oldest note_id
                    // FIXME! this is flawed because the note_id is assigned at note-on, which has no correlation to when the note-off happened.
                    // we need an 'age' based on time.
                    {
                        var maybe_best: ?usize = null;
                        for (self.slots) |maybe_slot, slot_index| {
                            if (maybe_slot) |slot| {
                                if (!slot.note_on) {
                                    if (maybe_best) |best| {
                                        if (slot.note_id < self.slots[best].?.note_id) {
                                            maybe_best = slot_index;
                                        }
                                    } else { // maybe_best == null
                                        maybe_best = slot_index;
                                    }
                                }
                            } else { // maybe_slot == null
                                // if there's still an empty slot, jump on that right now
                                return slot_index;
                            }
                        }
                        if (maybe_best) |best| {
                            return best;
                        }
                    }
                    // otherwise, we have no choice but to take over a track
                    // that's still in note-on state. pick the slot with the
                    // oldest note_id.
                    var best: usize = 0;
                    var slot_index: usize = 1; while (slot_index < polyphony) : (slot_index += 1) {
                        if (self.slots[slot_index].?.note_id < self.slots[best].?.note_id) {
                            best = slot_index;
                        }
                    }
                    return best;
                }

                // FIXME can this be changed to a generator pattern so we don't need the static arrays?
                pub fn dispatch(self: *@This(), iap: ImpulsesAndParamses) [polyphony]ImpulsesAndParamses {
                    var counts = [1]usize{0} ** polyphony;

                    var i: usize = 0; while (i < iap.paramses.len) : (i += 1) {
                        const impulse = iap.impulses[i];
                        const params = iap.paramses[i];

                        const slot_index = self.chooseSlot(impulse.note_id);

                        // std.debug.warn("slot_index={}\n", slot_index);

                        self.slots[slot_index] = SlotState {
                            .note_id = impulse.note_id,
                            .note_on = params.note_on,
                        };

                        self.impulses_array[slot_index][counts[slot_index]] = impulse;
                        self.paramses_array[slot_index][counts[slot_index]] = params;
                        counts[slot_index] += 1;
                    }

                    var result: [polyphony]ImpulsesAndParamses = undefined;
                    i = 0; while (i < polyphony) : (i += 1) {
                        result[i] = ImpulsesAndParamses {
                            .impulses = self.impulses_array[i][0..counts[i]],
                            .paramses = self.paramses_array[i][0..counts[i]],
                        };
                    }
                    return result;
                }
            };
        }
    };
}
