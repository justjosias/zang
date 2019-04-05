// in this example you can play a simple monophonic synth with the keyboard

const std = @import("std");
const harold = @import("harold");
const c = @import("common/sdl.zig");

const AUDIO_FORMAT = harold.AudioFormat.S16LSB;
const AUDIO_SAMPLE_RATE = 48000;
const AUDIO_BUFFER_SIZE = 2048;

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
  impulse_queue: harold.ImpulseQueue,

  next_impulse_id: usize, // does this not belong in the impulse_queue?
  frame_index: usize,

  osc: PulseModOscillator,
  env: harold.Envelope,
};

var buffers: AudioBuffers(AUDIO_BUFFER_SIZE) = undefined;

fn initAudioState() AudioState {
  return AudioState{
    .impulse_queue = harold.ImpulseQueue.init(),
    .next_impulse_id = 1,
    .frame_index = 0,
    .osc = PulseModOscillator.init(1.0, 1.5),
    .env = harold.Envelope.init(harold.EnvParams {
      .attack_duration = 0.025,
      .decay_duration = 0.1,
      .sustain_volume = 0.5,
      .release_duration = 1.0,
    }),
  };
}

fn paint(comptime buf_size: usize, as: *AudioState, bufs: *AudioBuffers(buf_size), sample_rate: u32) []f32 {
  const out = bufs.buf0[0..];
  const tmp0 = bufs.buf1[0..];
  const tmp1 = bufs.buf2[0..];
  const tmp2 = bufs.buf3[0..];
  const tmp3 = bufs.buf4[0..];

  harold.zero(out);

  if (!as.impulse_queue.isEmpty()) {
    // use ADSR envelope with pulse mod oscillator
    harold.zero(tmp0);
    as.osc.paintFromImpulses(as.frame_index, sample_rate, tmp0, as.impulse_queue.getImpulses(), tmp1, tmp2, tmp3);
    harold.zero(tmp1);
    as.env.paintFromImpulses(sample_rate, tmp1, as.impulse_queue.getImpulses(), as.frame_index);
    harold.multiply(out, tmp0, tmp1);
  }

  as.impulse_queue.flush(as.frame_index, out.len);

  as.frame_index += out.len;

  return out;
}

extern fn audioCallback(userdata_: ?*c_void, stream_: ?[*]u8, len_: c_int) void {
  const audio_state = @ptrCast(*AudioState, @alignCast(@alignOf(*AudioState), userdata_.?));
  const stream = stream_.?[0..@intCast(usize, len_)];

  const buf = paint(AUDIO_BUFFER_SIZE, audio_state, &buffers, AUDIO_SAMPLE_RATE);

  harold.mixDown(stream, buf, AUDIO_FORMAT);
}

pub fn main() !void {
  var audio_state = initAudioState();

  if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO) != 0) {
    c.SDL_Log(c"Unable to initialize SDL: %s", c.SDL_GetError());
    return error.SDLInitializationFailed;
  }
  errdefer c.SDL_Quit();

  const SDL_WINDOWPOS_UNDEFINED = @bitCast(c_int, c.SDL_WINDOWPOS_UNDEFINED_MASK);
  const window = c.SDL_CreateWindow(
    c"harold",
    SDL_WINDOWPOS_UNDEFINED,
    SDL_WINDOWPOS_UNDEFINED,
    640, 480,
    0,
  ) orelse {
    c.SDL_Log(c"Unable to create window: %s", c.SDL_GetError());
    return error.SDLInitializationFailed;
  };
  errdefer c.SDL_DestroyWindow(window);

  var want: c.SDL_AudioSpec = undefined;
  want.freq = AUDIO_SAMPLE_RATE;
  want.format = switch (AUDIO_FORMAT) {
    harold.AudioFormat.S8 => u16(c.AUDIO_S8),
    harold.AudioFormat.S16LSB => u16(c.AUDIO_S16LSB),
  };
  want.channels = 1;
  want.samples = AUDIO_BUFFER_SIZE;
  want.callback = audioCallback;
  want.userdata = &audio_state;

  const device: c.SDL_AudioDeviceID = c.SDL_OpenAudioDevice(
    0, // device name (NULL)
    0, // non-zero to open for recording instead of playback
    &want, // desired output format
    0, // obtained output format (NULL)
    0, // allowed changes: 0 means `obtained` will not differ from `want`, and SDL will do any necessary resampling behind the scenes
  );
  if (device == 0) {
    c.SDL_Log(c"Failed to open audio: %s", c.SDL_GetError());
    return error.SDLInitializationFailed;
  }
  errdefer c.SDL_CloseAudio();

  // this seems to match the value of SDL_GetTicks the first time the audio
  // callback is called
  const start_time = @intToFloat(f32, c.SDL_GetTicks()) / 1000.0;

  c.SDL_PauseAudioDevice(device, 0); // unpause

  var event: c.SDL_Event = undefined;

  while (c.SDL_WaitEvent(&event) != 0) {
    switch (event.type) {
      c.SDL_QUIT => {
        break;
      },
      c.SDL_KEYDOWN => {
        if (event.key.keysym.sym == c.SDLK_ESCAPE) {
          break;
        }
        if (event.key.repeat == 0) {
          keyEvent(&audio_state, device, start_time, event.key.keysym.sym, true);
        }
      },
      c.SDL_KEYUP => {
        keyEvent(&audio_state, device, start_time, event.key.keysym.sym, false);
      },
      else => {},
    }
  }

  c.SDL_LockAudioDevice(device);
  c.SDL_UnlockAudioDevice(device);
  c.SDL_CloseAudioDevice(device);
  c.SDL_DestroyWindow(window);
  c.SDL_Quit();
}

var g_note_held: ?i32 = null;

fn keyEvent(audio_state: *AudioState, device: c.SDL_AudioDeviceID, start_time: f32, key: i32, down: bool) void {
  const f = harold.note_frequencies;

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
    c.SDL_LockAudioDevice(device);

    const impulse_frame = getImpulseFrame(AUDIO_BUFFER_SIZE, AUDIO_SAMPLE_RATE, start_time, audio_state.frame_index);

    if (down) {
      audio_state.impulse_queue.push(impulse_frame, freq, audio_state.frame_index, AUDIO_BUFFER_SIZE);
      g_note_held = key;
    } else {
      if (if (g_note_held) |nh| nh == key else false) {
        audio_state.impulse_queue.push(impulse_frame, null, audio_state.frame_index, AUDIO_BUFFER_SIZE);
        g_note_held = null;
      }
    }

    c.SDL_UnlockAudioDevice(device);
  }
}

// come up with a frame index to start the sound at
fn getImpulseFrame(buffer_size: usize, sample_rate: usize, start_time: f32, current_frame_index: usize) usize {
  // `current_frame_index` is the END of the mix frame currently queued to be heard next
  const one_mix_frame = @intToFloat(f32, buffer_size) / @intToFloat(f32, sample_rate);

  // time of the start of the mix frame currently underway
  const mix_end = @intToFloat(f32, current_frame_index) / @intToFloat(f32, sample_rate);
  const mix_start = mix_end - one_mix_frame;

  const current_time = @intToFloat(f32, c.SDL_GetTicks()) / 1000.0 - start_time;

  // if everything is working properly, current_time should be
  // between mix_start and mix_end. there might be a little bit of an
  // offset but i'm not going to deal with that for now.

  // i just need to make sure that if this code queues up an impulse
  // that's in the "past" when it actually gets picked up by the
  // audio thread, it will still be picked up (somehow)!

  // FIXME - shouldn't be multiplied by 2! this is only to
  // compensate for the clocks sometimes starting out of sync
  const impulse_time = current_time + one_mix_frame * 2.0;
  const impulse_frame = @floatToInt(usize, impulse_time * @intToFloat(f32, sample_rate));

  return impulse_frame;
}
