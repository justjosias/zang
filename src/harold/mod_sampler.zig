const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;
const getNextNoteSpan = @import("note_span.zig").getNextNoteSpan;

fn getSample(data: []const u8, index: usize) f32 {
  if (index < data.len / 2) {
    const b0 = data[index * 2 + 0];
    const b1 = data[index * 2 + 1];

    const uval = u16(b0) | (u16(b1) << 8);
    const sval = @bitCast(i16, uval);

    return @intToFloat(f32, sval) / 32768.0;
  } else {
    return 0.0;
  }
}

pub const Sampler = struct {
  sample_data: []const u8,
  sample_rate: u32,
  // `sample_freq`: if null, ignore note frequencies and always play at
  // original speed. FIXME - this is confusing, because usually a null
  // frequency means NO sound...
  sample_freq: ?f32,

  t: f32,
  note_freq: ?f32,
  note_id: usize,

  pub fn init(sample_data: []const u8, sample_rate: u32, sample_freq: ?f32) Sampler {
    return Sampler{
      .sample_data = sample_data,
      .sample_rate = sample_rate,
      .sample_freq = sample_freq,
      .t = 0.0,
      .note_freq = null,
      .note_id = 0,
    };
  }

  // TODO - support looping

  pub fn paint(self: *Sampler, sample_rate: u32, buf: []f32) void {
    if (
      self.sample_rate == sample_rate and (
        self.sample_freq == null or
        self.note_freq == null or
        self.sample_freq.? == self.note_freq.?
      )
    ) {
      // no resampling needed
      const num_samples = self.sample_data.len / 2;
      var t = @floatToInt(usize, std.math.round(self.t));
      var i: usize = 0;

      if (t < num_samples) {
        const samples_remaining = num_samples - t;
        const samples_to_render = std.math.min(buf.len, samples_remaining);

        while (i < samples_to_render) : (i += 1) {
          buf[i] += getSample(self.sample_data, t + i);
        }
      }

      self.t += @intToFloat(f32, buf.len);
    } else {
      // resample (TODO - use a better filter)
      const note_ratio =
        if (self.sample_freq) |sample_freq|
          if (self.note_freq) |note_freq|
            note_freq / sample_freq
          else
            1.0
        else
          1.0;
      const ratio = @intToFloat(f32, self.sample_rate) / @intToFloat(f32, sample_rate) * note_ratio;
      var i: usize = 0;

      while (i < buf.len) : (i += 1) {
        const t0 = @floatToInt(usize, std.math.floor(self.t));
        const t1 = t0 + 1;
        const tfrac = @intToFloat(f32, t1) - self.t;

        const s0 = getSample(self.sample_data, t0);
        const s1 = getSample(self.sample_data, t1);

        const s = s0 * (1.0 - tfrac) + s1 * tfrac;

        buf[i] += s;

        self.t += ratio;
      }
    }
  }

  pub fn paintFromImpulses(
    self: *Sampler,
    sample_rate: u32,
    buf: []f32,
    impulses: []const Impulse,
    frame_index: usize,
  ) void {
    var start: usize = 0;

    while (start < buf.len) {
      const note_span = getNextNoteSpan(impulses, frame_index, start, buf.len);

      std.debug.assert(note_span.start == start);
      std.debug.assert(note_span.end > start);
      std.debug.assert(note_span.end <= buf.len);

      const buf_span = buf[note_span.start .. note_span.end];

      if (note_span.note) |note| {
        if (false) {
          // this debug log is useful to see if the thread timing is good.
          // if the threads were synced perfectly, you would never really see a sound starting at 0.
          // (should be uniformly distributed between 0 and buf.len)
          std.debug.warn("note {.1}. {} -> {}\n", note.freq, note_span.start, note_span.end);
        }

        if (note.id != self.note_id) {
          std.debug.assert(note.id > self.note_id);

          self.note_id = note.id;
          self.t = 0.0;
        }

        self.note_freq = note.freq;
        self.paint(sample_rate, buf_span);
      } else {
        // gap between notes. but keep playing (sampler currently ignores note
        // end events).

        // don't paint at all if note_freq is null. that means we haven't hit
        // the first note yet
        if (self.note_freq != null) {
          self.paint(sample_rate, buf_span);
        }
      }

      start = note_span.end;
    }
  }
};
