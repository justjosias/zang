// in this example you can play a simple monophonic synth with the keyboard

const std = @import("std");
const harold = @import("src/harold.zig");
const common = @import("examples/common.zig");
const c = @import("examples/common/sdl.zig");

pub const AUDIO_FORMAT = harold.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

// an example of a custom "module"
const PulseModOscillator = struct {
  carrier: harold.Oscillator,
  modulator: harold.Oscillator,
  dc: harold.DC,
  ratio: f32,

  fn init(ratio: f32, multiplier: f32) PulseModOscillator {
    return PulseModOscillator{
      .carrier = harold.Oscillator.init(harold.Waveform.Sine, 320.0, 1.0),
      .modulator = harold.Oscillator.init(harold.Waveform.Sine, 160.0, multiplier),
      .dc = harold.DC.init(),
      .ratio = ratio,
    };
  }

  fn paintFromImpulses(
    self: *PulseModOscillator,
    frame_index: usize,
    sample_rate: u32,
    out: []f32,
    track: []const harold.Impulse,
    tmp0: []f32,
    tmp1: []f32,
    tmp2: []f32,
  ) void {
    std.debug.assert(out.len == tmp0.len);
    std.debug.assert(out.len == tmp1.len);
    std.debug.assert(out.len == tmp2.len);

    harold.zero(tmp0);
    harold.zero(tmp1);
    self.dc.paintFrequencyFromImpulses(tmp0, track, frame_index);
    harold.multiplyScalar(tmp1, tmp0, self.ratio);
    harold.zero(tmp2);
    self.modulator.paintControlledFrequency(sample_rate, tmp2, tmp1);
    self.carrier.paintControlledPhaseAndFrequency(sample_rate, out, tmp2, tmp0);
  }
};

fn AudioBuffers(comptime buffer_size: usize) type {
  return struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
    buf4: [AUDIO_BUFFER_SIZE]f32,
  };
}

pub const AudioState = struct {
  frame_index: usize,

  iq0: harold.ImpulseQueue,
  osc0: PulseModOscillator,
  env0: harold.Envelope,

  iq1: harold.ImpulseQueue,
  osc1: PulseModOscillator,
  env1: harold.Envelope,
};

var buffers: AudioBuffers(AUDIO_BUFFER_SIZE) = undefined;

pub fn initAudioState() AudioState {
  return AudioState{
    .frame_index = 0,
    .iq0 = harold.ImpulseQueue.init(),
    .osc0 = PulseModOscillator.init(1.0, 1.5),
    .env0 = harold.Envelope.init(harold.EnvParams {
      .attack_duration = 0.025,
      .decay_duration = 0.1,
      .sustain_volume = 0.5,
      .release_duration = 1.0,
    }),
    .iq1 = harold.ImpulseQueue.init(),
    .osc1 = PulseModOscillator.init(1.0, 1.0),
    .env1 = harold.Envelope.init(harold.EnvParams {
      .attack_duration = 0.025,
      .decay_duration = 0.1,
      .sustain_volume = 0.5,
      .release_duration = 1.0,
    }),
  };
}

pub fn paint(as: *AudioState) []f32 {
  const out = buffers.buf0[0..];
  const tmp0 = buffers.buf1[0..];
  const tmp1 = buffers.buf2[0..];
  const tmp2 = buffers.buf3[0..];
  const tmp3 = buffers.buf4[0..];

  harold.zero(out);

  if (!as.iq0.isEmpty()) {
    // use ADSR envelope with pulse mod oscillator
    harold.zero(tmp0);
    as.osc0.paintFromImpulses(as.frame_index, AUDIO_SAMPLE_RATE, tmp0, as.iq0.getImpulses(), tmp1, tmp2, tmp3);
    harold.zero(tmp1);
    as.env0.paintFromImpulses(AUDIO_SAMPLE_RATE, tmp1, as.iq0.getImpulses(), as.frame_index);
    harold.multiply(out, tmp0, tmp1);
  }

  if (!as.iq1.isEmpty()) {
    // use ADSR envelope with pulse mod oscillator
    harold.zero(tmp0);
    as.osc1.paintFromImpulses(as.frame_index, AUDIO_SAMPLE_RATE, tmp0, as.iq1.getImpulses(), tmp1, tmp2, tmp3);
    harold.zero(tmp1);
    as.env1.paintFromImpulses(AUDIO_SAMPLE_RATE, tmp1, as.iq1.getImpulses(), as.frame_index);
    harold.multiply(out, tmp0, tmp1);
  }

  as.iq0.flush(as.frame_index, out.len);
  as.iq1.flush(as.frame_index, out.len);

  as.frame_index += out.len;

  return out;
}

var g_note_held0: ?i32 = null;
var g_note_held1: ?i32 = null;

const NoteParams = struct {
  iq: *harold.ImpulseQueue,
  nh: *?i32,
  freq: f32,
};

pub fn keyEvent(audio_state: *AudioState, key: i32, down: bool) ?common.KeyEvent {
  const f = harold.note_frequencies;

  if (switch (key) {
    c.SDLK_SPACE => NoteParams{ .iq = &audio_state.iq1, .nh = &g_note_held1, .freq = f.C4 / 4.0 },
    c.SDLK_a => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.C4 },
    c.SDLK_w => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.Cs4 },
    c.SDLK_s => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.D4 },
    c.SDLK_e => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.Ds4 },
    c.SDLK_d => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.E4 },
    c.SDLK_f => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.F4 },
    c.SDLK_t => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.Fs4 },
    c.SDLK_g => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.G4 },
    c.SDLK_y => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.Gs4 },
    c.SDLK_h => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.A4 },
    c.SDLK_u => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.As4 },
    c.SDLK_j => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.B4 },
    c.SDLK_k => NoteParams{ .iq = &audio_state.iq0, .nh = &g_note_held0, .freq = f.C5 },
    else => null,
  }) |params| {
    if (down) {
      params.nh.* = key;

      return common.KeyEvent{
        .iq = params.iq,
        .freq = params.freq,
      };
    } else {
      if (if (params.nh.*) |nh| nh == key else false) {
        params.nh.* = null;

        return common.KeyEvent{
          .iq = params.iq,
          .freq = null,
        };
      }
    }
  }

  return null;
}
