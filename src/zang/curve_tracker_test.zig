const std = @import("std");
const CurveTrackerNode = @import("curve_tracker.zig").CurveTrackerNode;
const CurveTracker = @import("curve_tracker.zig").CurveTracker;

test "CurveTracker" {
    var tracker = CurveTracker.init([]CurveTrackerNode {
        CurveTrackerNode{ .value = 440.0, .t = 0.0 },
        CurveTrackerNode{ .value = 550.0, .t = 0.2 },
        CurveTrackerNode{ .value = 330.0, .t = 0.4 },
    });

    const srate = 44100;
    const buflen = 4096;

    const nodes0 = tracker.getCurveNodes(srate, buflen);

    std.testing.expectEqual(usize(2), nodes0.len);
    std.testing.expectEqual(i32(0), nodes0[0].frame);
    std.testing.expectEqual(i32(8820), nodes0[1].frame);

    const nodes1 = tracker.getCurveNodes(srate, buflen);

    std.testing.expectEqual(usize(2), nodes1.len);
    std.testing.expectEqual(i32(-4096), nodes1[0].frame);
    std.testing.expectEqual(i32(4724), nodes1[1].frame);

    const nodes2 = tracker.getCurveNodes(srate, buflen);

    std.testing.expectEqual(usize(3), nodes2.len);
    std.testing.expectEqual(i32(-8192), nodes2[0].frame);
    std.testing.expectEqual(i32(628), nodes2[1].frame);
    std.testing.expectEqual(i32(9448), nodes2[2].frame);
}
