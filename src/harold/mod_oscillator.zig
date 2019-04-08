const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;
const getNextNoteSpan = @import("note_span.zig").getNextNoteSpan;

pub const Waveform = enum {
  Sine,
  Triangle,
  Square,
  Sawtooth,
};

pub fn tri(t: f32) f32 {
  const frac = t - std.math.floor(t);
  if (frac < 0.25) {
    return frac * 4.0;
  } else if (frac < 0.75) {
    return 1.0 - (frac - 0.25) * 4.0;
  } else {
    return (frac - 0.75) * 4.0 - 1.0;
  }
}

pub fn saw(t: f32) f32 {
  const frac = t - std.math.floor(t);
  return frac;
}

pub fn square(t: f32) f32 {
  const frac = t - std.math.floor(t);
  return if (frac < 0.5) f32(1.0) else f32(-1.0);
}

pub fn sin(t: f32) f32 {
  return std.math.sin(t * std.math.pi * 2.0);
}

fn oscFunc(waveform: Waveform) fn (t: f32) f32 {
  return switch (waveform) {
    Waveform.Sine => sin,
    Waveform.Triangle => tri,
    Waveform.Square => square,
    Waveform.Sawtooth => saw,
  };
}

fn osc(waveform: Waveform, t: f32) f32 {
  return oscFunc(waveform)(t);
}

pub const Oscillator = struct {
  waveform: Waveform,

  freq: f32,
  volume: f32,

  t: f32,

  pub fn init(waveform: Waveform, vol: f32) Oscillator {
    return Oscillator{
      .waveform = waveform,
      .freq = 0.0,
      .volume = vol,
      .t = 0.0,
    };
  }

  // paint with a constant frequency
  pub fn paint(self: *Oscillator, sample_rate: u32, buf: []f32) void {
    const volume = self.volume;
    const step = self.freq / @intToFloat(f32, sample_rate);
    var t = self.t;
    var i: usize = 0;

    switch (self.waveform) {
      Waveform.Sine => {
        while (i < buf.len) : (i += 1) {
          buf[i] += sin(t) * volume;
          t += step;
        }
      },
      Waveform.Triangle => {
        while (i < buf.len) : (i += 1) {
          buf[i] += tri(t) * volume;
          t += step;
        }
      },
      Waveform.Square => {
        while (i < buf.len) : (i += 1) {
          buf[i] += square(t) * volume;
          t += step;
        }
      },
      Waveform.Sawtooth => {
        while (i < buf.len) : (i += 1) {
          buf[i] += saw(t) * volume;
          t += step;
        }
      },
    }

    t -= std.math.trunc(t); // it actually goes out of tune without this!...

    self.t = t;
  }

  pub fn paintFromImpulses(
    self: *Oscillator,
    sample_rate: u32,
    buf: []f32,
    impulses: []const Impulse,
    frame_index: usize,
    // freq_mul: if present, multiply frequency by this. this gives you a way
    // to alter note frequencies without having out to a buffer and perform
    // operations on the entire buffer.
    // TODO - come up with a more general and systematic to apply functions to
    // notes
    freq_mul: ?f32,
  ) void {
    var start: usize = 0;

    while (start < buf.len) {
      const note_span = getNextNoteSpan(impulses, frame_index, start, buf.len);

      if (note_span.note) |note| {
        self.freq =
          if (freq_mul) |mul|
            note.freq * mul
          else
            note.freq;
      }

      self.paint(sample_rate, buf[note_span.start .. note_span.end]);

      start = note_span.end;
    }
  }

  pub fn paintControlledFrequency(self: *Oscillator, sample_rate: u32, buf: []f32, input_frequency: []const f32) void {
    const volume = self.volume;
    const inv = 1.0 / @intToFloat(f32, sample_rate);
    var t = self.t;
    var i: usize = 0;

    switch (self.waveform) {
      Waveform.Sine => {
        while (i < buf.len) : (i += 1) {
          const freq = input_frequency[i];
          buf[i] += sin(t) * volume;
          t += freq * inv;
        }
      },
      Waveform.Triangle => {
        while (i < buf.len) : (i += 1) {
          const freq = input_frequency[i];
          buf[i] += tri(t) * volume;
          t += freq * inv;
        }
      },
      Waveform.Square => {
        while (i < buf.len) : (i += 1) {
          const freq = input_frequency[i];
          buf[i] += square(t) * volume;
          t += freq * inv;
        }
      },
      Waveform.Sawtooth => {
        while (i < buf.len) : (i += 1) {
          const freq = input_frequency[i];
          buf[i] += saw(t) * volume;
          t += freq * inv;
        }
      },
    }

    t -= std.math.trunc(t); // it actually goes out of tune without this!...

    self.freq = input_frequency[buf.len - 1];
    self.t = t;
  }

  pub fn paintControlledPhaseAndFrequency(self: *Oscillator, sample_rate: u32, buf: []f32, input_phase: []const f32, input_frequency: []const f32) void {
    const volume = self.volume;
    const inv = 1.0 / @intToFloat(f32, sample_rate);
    var t = self.t;
    var i: usize = 0;

    switch (self.waveform) {
      Waveform.Sine => {
        while (i < buf.len) : (i += 1) {
          const phase = input_phase[i];
          const freq = input_frequency[i];
          buf[i] += sin(t + phase) * volume;
          t += freq * inv;
        }
      },
      Waveform.Triangle => {
        while (i < buf.len) : (i += 1) {
          const phase = input_phase[i];
          const freq = input_frequency[i];
          buf[i] += tri(t + phase) * volume;
          t += freq * inv;
        }
      },
      Waveform.Square => {
        while (i < buf.len) : (i += 1) {
          const phase = input_phase[i];
          const freq = input_frequency[i];
          buf[i] += square(t + phase) * volume;
          t += freq * inv;
        }
      },
      Waveform.Sawtooth => {
        while (i < buf.len) : (i += 1) {
          const phase = input_phase[i];
          const freq = input_frequency[i];
          buf[i] += saw(t + phase) * volume;
          t += freq * inv;
        }
      },
    }

    t -= std.math.trunc(t); // it actually goes out of tune without this!...

    self.freq = input_frequency[buf.len - 1];
    self.t = t;
  }

  // this function is an experiment. i'm not sure if zig will create new
  // functions based on the comptime args, like C++ template metaprogramming.
  // if so, i should be able to get rid of all the above functions. if not,
  // then this function is useless
  pub fn paintTemplate(
    self: *Oscillator,
    sample_rate: u32,
    buf: []f32,
    comptime waveform: Waveform,
    comptime controlled_phase: bool,
    input_phase: []const f32,
    comptime controlled_frequency: bool,
    input_frequency: []const f32,
  ) void {
    const volume = self.volume;
    const inv = 1.0 / @intToFloat(f32, sample_rate);
    var step = self.freq * inv;
    var t = self.t;
    var i: usize = 0;

    const function = oscFunc(waveform);

    while (i < buf.len) : (i += 1) {
      if (controlled_frequency) {
        step = input_frequency[i] * inv;
      }

      if (controlled_phase) {
        buf[i] += volume * function(t + input_phase[i]);
      } else {
        buf[i] += volume * function(t);
      }

      t += step;
    }

    t -= std.math.trunc(t); // it actually goes out of tune without this!...

    self.t = t;

    if (controlled_frequency) {
      self.freq = input_frequency[buf.len - 1];
    }
  }

  // if the above function is useable, then i could make another function that
  // unpacks every possible permutation of the comptime flags and calls into
  // that function
};
