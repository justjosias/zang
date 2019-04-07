// in this example a canned melody is played

const std = @import("std");
const harold = @import("harold");
const c = @import("common/sdl.zig");

const AUDIO_FORMAT = harold.AudioFormat.S16LSB;
const AUDIO_SAMPLE_RATE = 48000;
const AUDIO_BUFFER_SIZE = 2048;

const Note = harold.Note;
const f = harold.note_frequencies;
const track1Init = []Note{
  Note{ .freq = f.A4, .dur = 1 },
  Note{ .freq = f.G4, .dur = 1 },
  Note{ .freq = f.A4, .dur = 12 },
  Note{ .freq = f.G4, .dur = 1 },
  Note{ .freq = f.F4, .dur = 1 },
  Note{ .freq = f.E4, .dur = 1 },
  Note{ .freq = f.D4, .dur = 1 },
  Note{ .freq = f.Cs4, .dur = 8 },
  Note{ .freq = f.D4, .dur = 10 },
  Note{ .freq = null, .dur = 4 },

  Note{ .freq = f.A3, .dur = 1 },
  Note{ .freq = f.G3, .dur = 1 },
  Note{ .freq = f.A3, .dur = 12 },
  Note{ .freq = f.E3, .dur = 3 },
  Note{ .freq = f.F3, .dur = 3 },
  Note{ .freq = f.Cs3, .dur = 3 },
  Note{ .freq = f.D3, .dur = 10 },
  Note{ .freq = null, .dur = 4 },

  Note{ .freq = f.A2, .dur = 1 },
  Note{ .freq = f.G2, .dur = 1 },
  Note{ .freq = f.A2, .dur = 10 },
  Note{ .freq = f.G2, .dur = 1 },
  Note{ .freq = f.F2, .dur = 1 },
  Note{ .freq = f.E2, .dur = 1 },
  Note{ .freq = f.D2, .dur = 1 },
  Note{ .freq = f.Cs2, .dur = 8 },
  Note{ .freq = f.D2, .dur = 12 },
  Note{ .freq = null, .dur = 2 },

  Note{ .freq = f.D1, .dur = 128 },
};
const track2Init = []Note{
  Note{ .freq = f.A5, .dur = 1 },
  Note{ .freq = f.G5, .dur = 1 },
  Note{ .freq = f.A5, .dur = 12 },
  Note{ .freq = f.G5, .dur = 1 },
  Note{ .freq = f.F5, .dur = 1 },
  Note{ .freq = f.E5, .dur = 1 },
  Note{ .freq = f.D5, .dur = 1 },
  Note{ .freq = f.Cs5, .dur = 8 },
  Note{ .freq = f.D5, .dur = 10 },
  Note{ .freq = null, .dur = 4 },

  Note{ .freq = f.A4, .dur = 1 },
  Note{ .freq = f.G4, .dur = 1 },
  Note{ .freq = f.A4, .dur = 12 },
  Note{ .freq = f.E4, .dur = 3 },
  Note{ .freq = f.F4, .dur = 3 },
  Note{ .freq = f.Cs4, .dur = 3 },
  Note{ .freq = f.D4, .dur = 10 },
  Note{ .freq = null, .dur = 4 },

  Note{ .freq = f.A3, .dur = 1 },
  Note{ .freq = f.G3, .dur = 1 },
  Note{ .freq = f.A3, .dur = 10 },
  Note{ .freq = f.G3, .dur = 1 },
  Note{ .freq = f.F3, .dur = 1 },
  Note{ .freq = f.E3, .dur = 1 },
  Note{ .freq = f.D3, .dur = 1 },
  Note{ .freq = f.Cs3, .dur = 8 },
  Note{ .freq = f.D3, .dur = 12 },
  Note{ .freq = null, .dur = 2 },
};
const ofs = 130;
const A = 6;
const B = 6;
const C = 5;
const D = 4;
const E = 4;
const track3Init = []Note{
  Note{ .freq = null, .dur = ofs },
  Note{ .freq = f.Cs2, .dur = A + B + C + D + E + 30 },
  Note{ .freq = f.D2, .dur = 14 + (14 + 30) },
};
const track4Init = []Note{
  Note{ .freq = null, .dur = ofs + A },
  Note{ .freq = f.E2, .dur = B + C + D + E + 30 },
};
const track5Init = []Note{
  Note{ .freq = null, .dur = ofs + A + B },
  Note{ .freq = f.G2, .dur = C + D + E + 30 + (14) },
  Note{ .freq = f.E2, .dur = 14 },
  Note{ .freq = f.Fs2, .dur = 30 },
};
const track6Init = []Note{
  Note{ .freq = null, .dur = ofs + A + B + C },
  Note{ .freq = f.Bb2, .dur = D + E + 30 },
  Note{ .freq = f.A2, .dur = 14 + (14 + 30) },
};
const track7Init = []Note{
  Note{ .freq = null, .dur = ofs + A + B + C + D },
  Note{ .freq = f.Cs3, .dur = E + 30 },
};
const track8Init = []Note{
  Note{ .freq = null, .dur = ofs + A + B + C + D + E },
  Note{ .freq = f.E3, .dur = 30 },
  Note{ .freq = f.D3, .dur = 14 + (14 + 30) },
};

const NUM_TRACKS = 8;
const NOTE_DURATION = 0.08;

const tracks = [NUM_TRACKS][]const harold.Impulse {
  harold.compileSong(track1Init.len, track1Init, AUDIO_SAMPLE_RATE, NOTE_DURATION),
  harold.compileSong(track2Init.len, track2Init, AUDIO_SAMPLE_RATE, NOTE_DURATION),
  harold.compileSong(track3Init.len, track3Init, AUDIO_SAMPLE_RATE, NOTE_DURATION),
  harold.compileSong(track4Init.len, track4Init, AUDIO_SAMPLE_RATE, NOTE_DURATION),
  harold.compileSong(track5Init.len, track5Init, AUDIO_SAMPLE_RATE, NOTE_DURATION),
  harold.compileSong(track6Init.len, track6Init, AUDIO_SAMPLE_RATE, NOTE_DURATION),
  harold.compileSong(track7Init.len, track7Init, AUDIO_SAMPLE_RATE, NOTE_DURATION),
  harold.compileSong(track8Init.len, track8Init, AUDIO_SAMPLE_RATE, NOTE_DURATION),
};

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

  osc: [NUM_TRACKS]PulseModOscillator,
  env: [NUM_TRACKS]harold.Envelope,
};

var buffers: AudioBuffers(AUDIO_BUFFER_SIZE) = undefined;

fn initAudioState() AudioState {
  return AudioState{
    .frame_index = 0,
    .osc = [1]PulseModOscillator{
      PulseModOscillator.init(1.0, 1.5)
    } ** NUM_TRACKS,
    .env = [1]harold.Envelope{
      harold.Envelope.init(harold.EnvParams {
        .attack_duration = 0.025,
        .decay_duration = 0.1,
        .sustain_volume = 0.5,
        .release_duration = 0.15,
      })
    } ** NUM_TRACKS,
  };
}

fn paint(comptime buf_size: usize, as: *AudioState, bufs: *AudioBuffers(buf_size), sample_rate: u32) []f32 {
  const out = bufs.buf0[0..];
  const tmp0 = bufs.buf1[0..];
  const tmp1 = bufs.buf2[0..];
  const tmp2 = bufs.buf3[0..];
  const tmp3 = bufs.buf4[0..];

  harold.zero(out);

  var i: usize = 0;
  while (i < NUM_TRACKS) : (i += 1) {
    harold.zero(tmp0);
    as.osc[i].paintFromImpulses(as.frame_index, sample_rate, tmp0, tracks[i], tmp1, tmp2, tmp3);
    harold.zero(tmp1);
    as.env[i].paintFromImpulses(sample_rate, tmp1, tracks[i], as.frame_index);
    harold.multiply(out, tmp0, tmp1);
  }

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
