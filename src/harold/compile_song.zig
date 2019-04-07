const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;

pub const Note = struct {
  freq: ?f32, // null for silence
  dur: usize,
};

pub fn compileSong(comptime len: usize, notes: [len]Note, sample_rate: usize, note_duration: f32) [len + 1]Impulse {
  const samples_per_note = @floatToInt(usize, note_duration * @intToFloat(f32, sample_rate));

  var impulses: [len + 1]Impulse = undefined;

  var pos: usize = 0;
  var i: usize = 0;

  for (notes) |note| {
    impulses[i] = Impulse{
      .id = i + 1,
      .freq = note.freq,
      .frame = pos,
    };
    i += 1;
    pos += note.dur * samples_per_note;
  }

  // final note off event
  impulses[i] = Impulse{
    .id = i + 1,
    .freq = null,
    .frame = pos,
  };
  i += 1;

  std.debug.assert(i == len + 1);

  return impulses;
}
