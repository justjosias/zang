const harold = @import("harold");

pub const KeyEvent = struct {
  iq: *harold.ImpulseQueue,
  freq: ?f32,
};
