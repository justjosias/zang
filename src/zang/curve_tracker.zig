const std = @import("std");
const CurveNode = @import("curves.zig").CurveNode;

pub const CurveTrackerNode = struct {
    value: f32,
    t: f32,
};

pub const CurveTracker = struct {
    song: []const CurveTrackerNode,
    current_song_note: usize,
    current_song_note_offset: i32,
    next_song_note: usize,
    t: f32,
    curve_nodes: [32]CurveNode,

    pub fn init(song: []const CurveTrackerNode) CurveTracker {
        return CurveTracker {
            .song = song,
            .current_song_note = 0,
            .current_song_note_offset = 0,
            .next_song_note = 0,
            .t = 0.0,
            .curve_nodes = undefined,
        };
    }

    pub fn reset(self: *CurveTracker) void {
        self.current_song_note = 0;
        self.current_song_note_offset = 0;
        self.next_song_note = 0;
        self.t = 0.0;
    }

    pub fn getCurveNodes(self: *CurveTracker, sample_rate: f32, out_len: usize) []CurveNode {
        var count: usize = 0;

        // note: playback speed is factored into sample_rate
        const buf_time = @intToFloat(f32, out_len) / sample_rate;
        const end_t = self.t + buf_time;

        // add a note that was begun in a previous frame
        if (self.current_song_note < self.next_song_note) {
            self.curve_nodes[count] = CurveNode{
                .frame = self.current_song_note_offset,
                .value = self.song[self.current_song_note].value,
            };
            count += 1;
        }

        var one_past = false;
        for (self.song[self.next_song_note..]) |song_note| {
            const note_t = song_note.t;
            if (note_t >= end_t) {
                // keep one note past the end
                if (!one_past) {
                    one_past = true;
                } else {
                    break;
                }
            }
            const f = (note_t - self.t) / buf_time; // 0 to 1
            const rel_frame_index = @floatToInt(i32, f * @intToFloat(f32, out_len));
            // if there's already a note at this frame (from the previous note
            // carry-over), this should overwrite that one
            if (count > 0 and self.curve_nodes[count - 1].frame == rel_frame_index) {
                count -= 1;
            }
            self.curve_nodes[count] = CurveNode{
                .frame = rel_frame_index,
                .value = song_note.value,
            };
            count += 1;
            if (!one_past) {
                self.current_song_note = self.next_song_note;
                self.current_song_note_offset = 0;
                self.next_song_note += 1;
            }
        }

        self.t += buf_time;
        self.current_song_note_offset -= @intCast(i32, out_len);

        return self.curve_nodes[0..count];
    }
};

fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}
