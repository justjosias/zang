const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

pub const MyNoteParams = struct {
    speed_mul: f32,
};
pub const MyNotes = zang.Notes(MyNoteParams);

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    iq: MyNotes.ImpulseQueue,
    wav: zang.WavContents,
    sampler: zang.Triggerable(zang.Sampler),
    r: std.rand.Xoroshiro128,
    first: bool,

    pub fn init() MainModule {
        return MainModule {
            .iq = MyNotes.ImpulseQueue.init(),
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
            self.iq.push(0, MyNoteParams { .speed_mul = 1.0 });
        }

        zang.zero(out);

        {
            const impulses = self.iq.consume();

            var conv = zang.ParamsConverter(MyNoteParams, zang.Sampler.Params).init();
            for (conv.getPairs(impulses)) |*pair| {
                pair.dest = zang.Sampler.Params {
                    .freq = 1.0,
                    .sample_data = self.wav.data,
                    .sample_rate = @intToFloat(f32, self.wav.sample_rate),
                    .sample_freq = pair.source.speed_mul,
                    .loop = true,
                };
            }

            self.sampler.paintFromImpulses(sample_rate, [1][]f32{out}, [0][]f32{}, [0][]f32{}, conv.getImpulses());
        }

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, out_iq: **MyNotes.ImpulseQueue, out_params: *MyNoteParams) bool {
        if (down and key == c.SDLK_SPACE) {
            out_iq.* = &self.iq;
            out_params.* = MyNoteParams {
                .speed_mul = 0.5 + 1.0 * self.r.random.float(f32),
            };
            return true;
        }
        return false;
    }
};
