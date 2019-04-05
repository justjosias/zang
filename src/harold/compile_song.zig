const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;

const NOTE_DURATION = 0.2;

pub const Note = struct {
  freq: ?f32, // null for silence
  dur: usize,
};

fn countActualNotes(comptime len: usize, notes: [len]Note) usize {
  var count: usize = 0;
  for (notes) |note| {
    if (note.freq != null) {
      count += 1;
    }
  }
  return count;
}

pub fn compileSong(comptime len: usize, notes: [len]Note, sample_rate: usize) [countActualNotes(len, notes) + 1]Impulse {
  const samples_per_note = @floatToInt(usize, NOTE_DURATION * @intToFloat(f32, sample_rate));

  comptime const num_actual = countActualNotes(len, notes);
  var impulses: [num_actual + 1]Impulse = undefined;

  var pos: usize = 0;
  var i: usize = 0;

  for (notes) |note| {
    if (note.freq) |freq| {
      impulses[i] = Impulse{
        .id = i + 1,
        .freq = freq,
        .frame = pos,
      };
      i += 1;
    }
    pos += note.dur * samples_per_note;
  }

  // final note off event
  impulses[i] = Impulse{
    .id = i + 1,
    .freq = null,
    .frame = pos,
  };
  i += 1;

  std.debug.assert(i == num_actual + 1);

  return impulses;
}
