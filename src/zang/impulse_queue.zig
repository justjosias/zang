const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;

// impulse queue is used to create new impulses on the fly from the main thread
pub const ImpulseQueue = struct {
    array: [32]Impulse,
    length: usize,
    next_id: usize,

    pub fn init() ImpulseQueue {
        return ImpulseQueue{
            .array = undefined,
            .length = 0,
            .next_id = 1,
        };
    }

    pub fn isEmpty(self: *const ImpulseQueue) bool {
        return self.length == 0;
    }

    pub fn getImpulses(self: *const ImpulseQueue) []const Impulse {
        return self.array[0..self.length];
    }

    // call this in the main thread (with mutex locked)
    pub fn push(
        self: *ImpulseQueue,
        impulse_frame: usize,
        freq: ?f32,
        current_frame_index: usize,
    ) void {
        if (self.length >= self.array.len) {
            std.debug.warn("outta spots\n");
            return;
        }

        const id = self.next_id;
        self.next_id += 1;

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
            var min_frame = current_frame_index;

            if (self.length > 0) {
                const last_impulse = self.array[self.length - 1];

                if (last_impulse.frame > min_frame) {
                    min_frame = last_impulse.frame;
                }
            }

            break :blk min_frame;
        };

        self.array[self.length] = Impulse{
            .id = id,
            .frame = std.math.max(min_frame, impulse_frame),
            .freq = freq,
        };
        self.length += 1;
    }

    // call this in the audio thread, after mixing
    pub fn flush(self: *ImpulseQueue, current_frame_index: usize, frame_length: usize) void {
        const next_frame_index = current_frame_index + frame_length;

        // delete all impulses that started before the end of this buffer, except
        // the last one (since that one will sustain into the next frame).

        // find the first future impulse.
        var i: usize = 0;
        while (i < self.length) : (i += 1) {
            if (self.array[i].frame >= next_frame_index) {
                break;
            }
        }

        // now, i is equal to the index of the first future impulse, or, if there
        // were none, the end of the queue.

        // now, delete everything up to that point, except for the last one before
        // that point (because that one will sustain into the future).
        if (i > 1) {
            const num_to_delete = i - 1;
            i = 0;
            while (i < self.length - num_to_delete) : (i += 1) {
                self.array[i] = self.array[i + num_to_delete];
            }
            self.length -= num_to_delete;
        }
    }
};
