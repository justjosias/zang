const std = @import("std");
const zang = @import("zang");
const wav = @import("wav");
const common = @import("common.zig");
const c = @import("common/c.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 44100;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    \\example_sampler
    \\
    \\Loop a WAV file.
    \\
    \\Press spacebar to reset the sampler with a randomly
    \\selected speed between 50% and 150%.
    \\
    \\Press 'b' to do the same, but with the sound playing
    \\in reverse.
    \\
    \\Press 'd' to toggle distortion.
;

fn readWav(comptime filename: []const u8) !zang.Sample {
    const buf = @embedFile(filename);
    var sis = std.io.SliceInStream.init(buf);
    const stream = &sis.stream;

    const Loader = wav.Loader(std.io.SliceInStream.Error, true);
    const preloaded = try Loader.preload(stream);

    // don't call Loader.load because we're working on a slice, so we can just
    // take a subslice of it
    return zang.Sample {
        .num_channels = preloaded.num_channels,
        .sample_rate = preloaded.sample_rate,
        .format = switch (preloaded.format) {
            .U8 => zang.SampleFormat.U8,
            .S16LSB => zang.SampleFormat.S16LSB,
            .S24LSB => zang.SampleFormat.S24LSB,
            .S32LSB => zang.SampleFormat.S32LSB,
        },
        .data = buf[sis.pos .. sis.pos + preloaded.getNumBytes()],
    };
}

pub const MainModule = struct {
    pub const num_outputs = 1;
    pub const num_temps = 1;

    sample: zang.Sample,
    iq: zang.Notes(zang.Sampler.Params).ImpulseQueue,
    idgen: zang.IdGenerator,
    sampler: zang.Sampler,
    trigger: zang.Trigger(zang.Sampler.Params),
    distortion: zang.Distortion,
    r: std.rand.Xoroshiro128,
    distort: bool,
    first: bool,

    pub fn init() MainModule {
        return MainModule {
            .sample = readWav("drumloop.wav") catch unreachable,
            .iq = zang.Notes(zang.Sampler.Params).ImpulseQueue.init(),
            .idgen = zang.IdGenerator.init(),
            .sampler = zang.Sampler.init(),
            .trigger = zang.Trigger(zang.Sampler.Params).init(),
            .distortion = zang.Distortion.init(),
            .r = std.rand.DefaultPrng.init(0),
            .distort = false,
            .first = true,
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        if (self.first) {
            self.first = false;
            self.iq.push(0, self.idgen.nextId(), zang.Sampler.Params {
                .sample_rate = AUDIO_SAMPLE_RATE,
                .sample = self.sample,
                .channel = 0,
                .loop = true,
            });
        }

        zang.zero(span, temps[0]);

        var ctr = self.trigger.counter(span, self.iq.consume());
        while (self.trigger.next(&ctr)) |result| {
            self.sampler.paint(result.span, [1][]f32{temps[0]}, [0][]f32{}, result.note_id_changed, result.params);
        }
        zang.multiplyWithScalar(span, temps[0], 2.5);

        if (self.distort) {
            self.distortion.paint(span, [1][]f32{outputs[0]}, [0][]f32{}, zang.Distortion.Params {
                .input = temps[0],
                .distortion_type = .Overdrive,
                .ingain = 0.9,
                .outgain = 0.5,
                .offset = 0.0,
            });
        } else {
            zang.addInto(span, outputs[0], temps[0]);
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (down and key == c.SDLK_SPACE) {
            self.iq.push(impulse_frame, self.idgen.nextId(), zang.Sampler.Params {
                .sample_rate = AUDIO_SAMPLE_RATE * (0.5 + 1.0 * self.r.random.float(f32)),
                .sample = self.sample,
                .channel = 0,
                .loop = true,
            });
        }
        if (down and key == c.SDLK_b) {
            self.iq.push(impulse_frame, self.idgen.nextId(), zang.Sampler.Params {
                .sample_rate = AUDIO_SAMPLE_RATE * -(0.5 + 1.0 * self.r.random.float(f32)),
                .sample = self.sample,
                .channel = 0,
                .loop = true,
            });
        }
        if (down and key == c.SDLK_d) {
            self.distort = !self.distort;
        }
    }
};
