const std = @import("std");

const CurveNode = @import("curves.zig").CurveNode;
const getNextCurveSpan = @import("curves.zig").getNextCurveSpan;

pub const InterpolationFunction = enum {
    Linear,
    SmoothStep,
};

pub const Curve = struct {
    function: InterpolationFunction,

    pub fn init(function: InterpolationFunction) Curve {
        return Curve{
            .function = function,
        };
    }

    pub fn paintFromCurve(
        self: *Curve,
        sample_rate: usize,
        buf: []f32,
        curve_nodes: []const CurveNode,
        frame_index: usize,
        freq_mul: ?f32,
    ) void {
        var start: usize = 0;

        while (start < buf.len) {
            const curve_span = getNextCurveSpan(curve_nodes, frame_index, start, buf.len);

            if (curve_span.values) |values| {
                // the full range between nodes
                const fstart = values.start_node.frame;
                const fend = values.end_node.frame;

                // the part of the above range that we are currently painting
                const paint_start = frame_index + curve_span.start;
                const paint_end = frame_index + curve_span.end;

                std.debug.assert(fstart < fend);
                std.debug.assert(fstart <= paint_start);
                std.debug.assert(paint_start < paint_end);
                std.debug.assert(paint_end <= fend);

                // 'x' values are 0-1
                const start_x = @intToFloat(f32, paint_start - fstart) / @intToFloat(f32, fend - fstart);

                var start_value = values.start_node.freq;
                var value_delta = values.end_node.freq - values.start_node.freq;

                if (freq_mul) |mul| {
                    start_value *= mul;
                    value_delta *= mul;
                }

                const x_step = 1.0 / @intToFloat(f32, fend - fstart);

                var i: usize = curve_span.start;

                switch (self.function) {
                    .Linear => {
                        var y = start_value + start_x * value_delta;
                        var y_step = x_step * value_delta;

                        while (i < curve_span.end) : (i += 1) {
                            buf[i] += y;
                            y += y_step;
                        }
                    },
                    .SmoothStep => {
                        var x = start_x;

                        while (i < curve_span.end) : (i += 1) {
                            buf[i] += start_value + x * x * (3.0 - 2.0 * x) * value_delta;
                            x += x_step;
                        }
                    },
                }
            }

            start = curve_span.end;
        }
    }
};
