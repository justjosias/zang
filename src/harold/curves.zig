const std = @import("std");

// curves are like notes except the value will be interpolated in between them.
// they can't be created in real-time
pub const CurveNode = struct {
    frame: usize, // frames (e.g. 44100 for one second in)
    freq: f32, // TODO - rename to 'value'
};

pub const CurveSpanValues = struct {
    start_node: CurveNode,
    end_node: CurveNode,
};

pub const CurveSpan = struct {
    start: usize,
    end: usize,
    values: ?CurveSpanValues, // if null, this is a silent gap between curves
};

pub fn getNextCurveSpan(
    curve_nodes: []const CurveNode,
    frame_index: usize,
    dest_start: usize,
    dest_end: usize,
) CurveSpan {
    std.debug.assert(dest_start < dest_end);

    for (curve_nodes) |curve_node, i| {
        const start_pos = curve_node.frame;

        if (start_pos >= frame_index + dest_end) {
            // this curve_node (and all after it, since they're in chronological order)
            // starts after the end of the buffer
            break;
        }

        // this span ends at the start of the next curve_node (if one exists), or the
        // end of the buffer, whichever comes first
        const end_pos =
            if (i < curve_nodes.len - 1)
                std.math.min(frame_index + dest_end, curve_nodes[i + 1].frame)
            else
                frame_index + dest_end;

        if (end_pos <= frame_index + dest_start) {
            // curve_node is entirely in the past. skip it
            continue;
        }

        const note_start_clipped =
            if (start_pos > frame_index + dest_start)
                start_pos - frame_index
            else
                dest_start;

        if (note_start_clipped > dest_start) {
            // gap before the note begins
            return CurveSpan{
                .start = dest_start,
                .end = note_start_clipped,
                .values = null,
            };
        }

        const note_end = end_pos - frame_index;
        const note_end_clipped =
            if (note_end > dest_end)
                dest_end
            else
                note_end;

        return CurveSpan{
            .start = note_start_clipped,
            .end = note_end_clipped,
            .values =
                if (i < curve_nodes.len - 1)
                    CurveSpanValues{
                        .start_node = curve_node,
                        .end_node = curve_nodes[i + 1],
                    }
                else
                    null,
        };
    }

    std.debug.assert(dest_start < dest_end);

    return CurveSpan{
        .start = dest_start,
        .end = dest_end,
        .values = null,
    };
}
