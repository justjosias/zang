const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 44100;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_sampler
    c\\
    c\\Loop a WAV file.
    c\\
    c\\Press spacebar to reset the sampler
    c\\with a randomly selected speed between
    c\\50% and 150%.
;

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 0;

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

    pub fn paint(self: *MainModule, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        if (self.first) {
            self.first = false;
            self.iq.push(0, zang.Sampler.Params {
                .sample_rate = AUDIO_SAMPLE_RATE,
                .wav = self.wav,
                .loop = true,
            });
        }

        self.sampler.paintFromImpulses(outputs, temps, self.iq.consume());
        zang.multiplyWithScalar(outputs[0], 2.5);
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (down and key == c.SDLK_SPACE) {
            self.iq.push(impulse_frame, zang.Sampler.Params {
                .sample_rate = AUDIO_SAMPLE_RATE * (0.5 + 1.0 * self.r.random.float(f32)),
                .wav = self.wav,
                .loop = true,
            });
        }
    }
};
