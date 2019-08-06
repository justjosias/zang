const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/c.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 44100;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_sampler
    c\\
    c\\Loop a WAV file.
    c\\
    c\\Press spacebar to reset the sampler with a randomly
    c\\selected speed between 50% and 150%.
    c\\
    c\\Press 'b' to do the same, but with the sound playing
    c\\in reverse.
    c\\
    c\\Press 'd' to toggle distortion.
;

pub const MainModule = struct {
    pub const num_outputs = 1;
    pub const num_temps = 1;

    wav: zang.WavContents,
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
            .wav = zang.readWav(@embedFile("drumloop.wav")) catch unreachable,
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
                .wav = self.wav,
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
                .wav = self.wav,
                .loop = true,
            });
        }
        if (down and key == c.SDLK_b) {
            self.iq.push(impulse_frame, self.idgen.nextId(), zang.Sampler.Params {
                .sample_rate = AUDIO_SAMPLE_RATE * -(0.5 + 1.0 * self.r.random.float(f32)),
                .wav = self.wav,
                .loop = true,
            });
        }
        if (down and key == c.SDLK_d) {
            self.distort = !self.distort;
        }
    }
};
