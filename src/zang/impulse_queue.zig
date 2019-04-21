const std = @import("std");

const Impulse = @import("types.zig").Impulse;
const NoteSpanNote = @import("types.zig").NoteSpanNote;
const DynamicNoteTracker = @import("note_tracker.zig").DynamicNoteTracker;

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

fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}
