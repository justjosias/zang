const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;
const getNextNoteSpan = @import("note_span.zig").getNextNoteSpan;
const paintLineTowards = @import("paint_line.zig").paintLineTowards;

pub const Portamento = struct {
  velocity: f32,
  value: f32,
  goal: f32,
  gap: bool,

  pub fn init(velocity: f32) Portamento {
    return Portamento{
      .velocity = velocity,
      .value = 0.0,
      .goal = 0.0,
      .gap = true,
    };
  }

  pub fn paint(self: *Portamento, sample_rate: u32, buf: []f32) void {
    if (self.velocity <= 0.0) {
      self.value = self.goal;
      std.mem.set(f32, buf, self.goal);
    } else {
      var i: u31 = 0;

      if (paintLineTowards(&self.value, sample_rate, buf, &i, 1.0 / self.velocity, self.goal)) {
        // reached the goal
        std.mem.set(f32, buf[i..], self.goal);
      }
    }
  }

  pub fn paintFromImpulses(
    self: *Portamento,
    sample_rate: u32,
    buf: []f32,
    impulses: []const Impulse,
    frame_index: usize,
  ) void {
    var start: usize = 0;

    while (start < buf.len) {
      const note_span = getNextNoteSpan(impulses, frame_index, start, buf.len);

      if (note_span.note) |note| {
        if (self.gap) {
          // if this note comes after a gap, snap instantly to the goal frequency
          self.value = note.freq;
          self.gap = false;
        }
        self.goal = note.freq;
      } else {
        self.gap = true;
      }

      self.paint(sample_rate, buf[note_span.start .. note_span.end]);

      start = note_span.end;
    }
  }
};
