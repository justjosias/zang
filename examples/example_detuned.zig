// in this example you can play a simple monophonic synth with the keyboard

const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

const A4 = 440.0;

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
    buf4: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

const MyNoteParams = struct {
    freq: f32,
    note_on: bool,
};
const MyNotes = zang.Notes(MyNoteParams);

pub const MainModule = struct {
    noise: zang.Noise,
    noise_filter: zang.Filter,
    iq: MyNotes.ImpulseQueue,
    key: ?i32,
    dc: zang.Triggerable(zang.DC),
    osc: zang.Oscillator,
    env: zang.Triggerable(zang.Envelope),
    main_filter: zang.Filter,

    pub fn init() MainModule {
        return MainModule {
            .noise = zang.Noise.init(0),
            .noise_filter = zang.Filter.init(),
            .iq = MyNotes.ImpulseQueue.init(),
            .key = null,
            .dc = zang.initTriggerable(zang.DC.init()),
            .osc = zang.Oscillator.init(),
            .env = zang.initTriggerable(zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            })),
            .main_filter = zang.Filter.init(),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];
        const tmp2 = g_buffers.buf3[0..];

        zang.zero(out);

        // tmp0 = filtered noise
        // note: filter frequency is set to 4hz. i wanted to go slower but
        // unfortunately at below 4, the filter degrades and the output
        // frequency slowly sinks to zero
        zang.zero(tmp1);
        self.noise.paintSpan(sample_rate, [1][]f32{tmp1}, [0][]f32{}, zang.Noise.Params {});
        zang.zero(tmp0);
        self.noise_filter.paintSpan(sample_rate, [1][]f32{tmp0}, [0][]f32{}, zang.Filter.Params {
            .input = tmp1,
            .filterType = .LowPass,
            .cutoff = zang.cutoffFromFrequency(4.0, sample_rate),
            .resonance = 0.0,
        });
        zang.multiplyWithScalar(tmp0, 200.0); // intensity of warble effect

        {
            // add note frequencies onto filtered noise
            const impulses = self.iq.consume();

            {
                var conv = zang.ParamsConverter(MyNoteParams, zang.DC.Params).init();
                for (conv.getPairs(impulses)) |*pair| {
                    pair.dest = zang.DC.Params {
                        .value = pair.source.freq,
                    };
                }
                self.dc.paintFromImpulses(sample_rate, [1][]f32{tmp0}, [0][]f32{}, conv.getImpulses());
            }
            // paint with oscillator into tmp1
            zang.zero(tmp1);
            self.osc.paintControlledFrequency(sample_rate, tmp1, .Sawtooth, tmp0, 0.5);
            // combine with envelope
            zang.zero(tmp0);
            {
                var conv = zang.ParamsConverter(MyNoteParams, zang.Envelope.Params).init();
                self.env.paintFromImpulses(sample_rate, [1][]f32{tmp0}, [0][]f32{}, conv.autoStructural(impulses));
            }
            zang.zero(tmp2);
            zang.multiply(tmp2, tmp1, tmp0);
            // add main filter
            self.main_filter.paintSpan(sample_rate, [1][]f32{out}, [0][]f32{}, zang.Filter.Params {
                .input = tmp2,
                .filterType = .LowPass,
                .cutoff = zang.cutoffFromFrequency(880.0, sample_rate),
                .resonance = 0.9,
            });
            // volume boost
            zang.multiplyWithScalar(out, 2.0);
        }

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, MyNoteParams { .freq = A4 * rel_freq * 0.5, .note_on = down });
            }
        }
    }
};
