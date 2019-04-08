// in this example a little melody plays every time you hit a key

const std = @import("std");
const harold = @import("harold");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = harold.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

const Note = common.Note;
const f = harold.note_frequencies;
const subtrackInit = []Note{
  Note{ .freq = f.C4, .dur = 1 },
  Note{ .freq = f.Ab3, .dur = 1 },
  Note{ .freq = f.G3, .dur = 1 },
  Note{ .freq = f.Eb3, .dur = 1 },
  Note{ .freq = f.C3, .dur = 1 },
};

const NOTE_DURATION = 0.1;

const subtrack = common.compileSong(subtrackInit.len, subtrackInit, AUDIO_SAMPLE_RATE, NOTE_DURATION);

// an example of a custom "module"
const SubtrackPlayer = struct {
  osc: harold.Oscillator,
  env: harold.Envelope,
  sub_frame_index: usize,
  note_id: usize,
  freq: f32,

  fn init() SubtrackPlayer {
    return SubtrackPlayer{
      .osc = harold.Oscillator.init(harold.Waveform.Sawtooth, 1.0),
      .env = harold.Envelope.init(harold.EnvParams {
        .attack_duration = 0.025,
        .decay_duration = 0.1,
        .sustain_volume = 0.5,
        .release_duration = 0.15,
      }),
      .sub_frame_index = 0,
      .note_id = 0,
      .freq = 0.0,
    };
  }

  fn paint(self: *SubtrackPlayer, sample_rate: u32, out: []f32, tmp0: []f32, tmp1: []f32) void {
    const freq_mul = self.freq / 440.0;

    harold.zero(tmp0);
    self.osc.paintFromImpulses(sample_rate, tmp0, subtrack, self.sub_frame_index, freq_mul);
    harold.zero(tmp1);
    self.env.paintFromImpulses(sample_rate, tmp1, subtrack, self.sub_frame_index);
    harold.multiply(out, tmp0, tmp1);

    self.sub_frame_index += out.len;
  }

  fn paintFromImpulses(
    self: *SubtrackPlayer,
    sample_rate: u32,
    out: []f32,
    track: []const harold.Impulse,
    tmp0: []f32,
    tmp1: []f32,
    frame_index: usize,
  ) void {
    std.debug.assert(out.len == tmp0.len);
    std.debug.assert(out.len == tmp1.len);

    var start: usize = 0;

    while (start < out.len) {
      const note_span = harold.getNextNoteSpan(track, frame_index, start, out.len);

      std.debug.assert(note_span.start == start);
      std.debug.assert(note_span.end > start);
      std.debug.assert(note_span.end <= out.len);

      const buf_span = out[note_span.start .. note_span.end];
      const tmp0_span = tmp0[note_span.start .. note_span.end];
      const tmp1_span = tmp1[note_span.start .. note_span.end];

      if (note_span.note) |note| {
        if (note.id != self.note_id) {
          std.debug.assert(note.id > self.note_id);

          self.note_id = note.id;
          self.freq = note.freq;
          self.env.note_id = 0; // TODO - make an API method for this
          self.sub_frame_index = 0;
        }

        self.paint(sample_rate, buf_span, tmp0_span, tmp1_span);
      } else {
        // gap between notes. but keep playing (sampler currently ignores note
        // end events).

        // don't paint at all if note_freq is null. that means we haven't hit
        // the first note yet
        if (self.note_id > 0) {
          self.paint(sample_rate, buf_span, tmp0_span, tmp1_span);
        }
      }

      start = note_span.end;
    }
  }
};

fn AudioBuffers(comptime buffer_size: usize) type {
  return struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
  };
}

pub const AudioState = struct {
  frame_index: usize,

  iq: harold.ImpulseQueue,
  subtrack_player: SubtrackPlayer,
};

var buffers: AudioBuffers(AUDIO_BUFFER_SIZE) = undefined;

pub fn initAudioState() AudioState {
  return AudioState{
    .frame_index = 0,
    .iq = harold.ImpulseQueue.init(),
    .subtrack_player = SubtrackPlayer.init(),
  };
}

pub fn paint(as: *AudioState) []f32 {
  const out = buffers.buf0[0..];
  const tmp0 = buffers.buf1[0..];
  const tmp1 = buffers.buf2[0..];

  harold.zero(out);

  as.subtrack_player.paintFromImpulses(AUDIO_SAMPLE_RATE, out, as.iq.getImpulses(), tmp0, tmp1, as.frame_index);

  as.iq.flush(as.frame_index, out.len);

  as.frame_index += out.len;

  return out;
}

pub fn keyEvent(audio_state: *AudioState, key: i32, down: bool) ?common.KeyEvent {
  if (!down) {
    return null;
  }

  if (switch (key) {
    c.SDLK_a => f.C4,
    c.SDLK_w => f.Cs4,
    c.SDLK_s => f.D4,
    c.SDLK_e => f.Ds4,
    c.SDLK_d => f.E4,
    c.SDLK_f => f.F4,
    c.SDLK_t => f.Fs4,
    c.SDLK_g => f.G4,
    c.SDLK_y => f.Gs4,
    c.SDLK_h => f.A4,
    c.SDLK_u => f.As4,
    c.SDLK_j => f.B4,
    c.SDLK_k => f.C5,
    else => null,
  }) |freq| {
    return common.KeyEvent{
      .iq = &audio_state.iq,
      .freq = freq,
    };
  }
  // if (key == c.SDLK_SPACE and down) {
  //   return common.KeyEvent{
  //     .iq = &audio_state.iq,
  //     .freq = 440.0,
  //   };
  // }

  return null;
}
