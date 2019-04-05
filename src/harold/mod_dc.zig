const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;
const getNextNoteSpan = @import("note_span.zig").getNextNoteSpan;

pub const DC = struct {
  value: f32,

  pub fn init() DC {
    return DC{
      .value = 0.0,
    };
  }

  // this function is like a portamento that snaps instantly
  pub fn paintFrequencyFromImpulses(
    self: *DC,
    buf: []f32,
    impulses: []const Impulse,
    frame_index: usize,
  ) void {
    var start: usize = 0;

    while (start < buf.len) {
      const note_span = getNextNoteSpan(impulses, frame_index, start, buf.len);

      if (note_span.note) |note| {
        self.value = note.freq;
      }

      var i: usize = note_span.start;
      while (i < note_span.end) : (i += 1) {
        buf[i] += self.value;
      }

      start = note_span.end;
    }
  }
};
