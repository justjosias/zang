const harold = @import("../src/harold.zig");

pub const KeyEvent = struct {
  iq: *harold.ImpulseQueue,
  freq: ?f32,
};
