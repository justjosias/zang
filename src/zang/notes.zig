const std = @import("std");

pub const Impulse = struct {
    frame: i32, // frames (e.g. 44100 for one second in)
    note: ?NoteSpanNote, // null if it's a silent gap
    next: ?*const Impulse,
};

pub const NoteSpanNote = struct {
    id: usize,
    freq: f32,
};

pub const SongNote = struct {
    freq: ?f32, // TODO rename to value
    t: f32,
};

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
// TODO - somehow generalize the note value. currently it's a frequency but you
// might want to use it for something else, like filter cutoff. maybe the
// module even has multiple paint methods?
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
        defer self.length = 0;

        return self.dyn_tracker.getImpulses(if (self.length > 0) &self.array[0] else null);
    }

    pub fn push(self: *ImpulseQueue, impulse_frame: usize, freq: ?f32) void {
        const current_frame_index = 0; // TODO remove

        if (self.length >= self.array.len) {
            std.debug.warn("outta spots\n");
            return;
        }

        // because we're in the main thread, `current_frame_index` points to the
        // beginning of the next mix invocation.

        // rules:
        // - never create an impulse that is in the past. if we did, the start of
        //   the sound would get cut off.
        // - never create an impulse before an already scheduled impulse. they are
        //   expected to be in chronological order. (this situation might occur if
        //   the caller uses complicated time-syncing logic to calculate the
        //   impulse_frame.)
        // assume that this method was called in good faith, and that the caller is
        // really trying to play a sound in the near future. so never throw away
        // the sound if it's "too soon". instead always clamp it.
        const min_frame = blk: {
            var min_frame: i32 = current_frame_index;

            if (self.length > 0) {
                const last_impulse = self.array[self.length - 1];

                if (last_impulse.frame > min_frame) {
                    min_frame = last_impulse.frame;
                }
            }

            break :blk min_frame;
        };

        const note = blk: {
            if (freq) |actual_freq| {
                const id = self.next_id;
                self.next_id += 1;
                break :blk NoteSpanNote {
                    .id = id,
                    .freq = actual_freq,
                };
            } else {
                break :blk null;
            }
        };

        self.array[self.length] = Impulse{
            .frame = max(i32, min_frame, @intCast(i32, impulse_frame)),
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
    // `freq_mul`: if present, multiply frequency by this. this gives you a way
    // to alter note frequencies without having to write to a buffer and perform
    // operations on the entire buffer.
    // TODO - come up with a more general and systematic to apply functions to
    // notes?
    pub fn getImpulses(self: *NoteTracker, sample_rate: f32, out_len: usize, freq_mul: ?f32) ?*const Impulse {
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
                    .note =
                        if (song_note.freq) |freq|
                            NoteSpanNote {
                                .id = self.next_song_note,
                                .freq =
                                    if (freq_mul) |mul|
                                        freq * mul
                                    else
                                        freq,
                            }
                        else
                            null,
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

fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}

fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}