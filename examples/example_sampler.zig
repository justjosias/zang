const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    iq: zang.Notes(zang.Sampler.Params).ImpulseQueue,
    wav: zang.WavContents,
    sampler: zang.Triggerable(zang.Sampler),
    r: std.rand.Xoroshiro128,
    first: bool,

    pub fn init() MainModule {
        return MainModule {
            .iq = zang.Notes(zang.Sampler.Params).ImpulseQueue.init(),
            .wav = zang.readWav(@embedFile("drumloop.wav")) catch unreachable,
            .sampler = zang.initTriggerable(zang.Sampler.init()),
            .r = std.rand.DefaultPrng.init(0),
            .first = true,
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];

        if (self.first) {
            self.first = false;
            self.iq.push(0, zang.Sampler.Params {
                .freq = 1.0,
                .sample_data = self.wav.data,
                .sample_rate = @intToFloat(f32, self.wav.sample_rate),
                .sample_freq = null,
                .loop = true,
            });
        }

        zang.zero(out);

        self.sampler.paintFromImpulses(sample_rate, [1][]f32{out}, [0][]f32{}, self.iq.consume());

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (down and key == c.SDLK_SPACE) {
            self.iq.push(impulse_frame, zang.Sampler.Params {
                .freq = 1.0,
                .sample_data = self.wav.data,
                .sample_rate = @intToFloat(f32, self.wav.sample_rate),
                .sample_freq = 0.5 + 1.0 * self.r.random.float(f32),
                .loop = true,
            });
        }
    }
};
