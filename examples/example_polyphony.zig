// this a "brute force" approach to polyphony... every possible note gets its
// own voice that is always running. well, it works
// also you can press spacebar to cycle through various levels of decimation

const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

const A4 = 220.0;

const Polyphony = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct {
        note_held: [common.key_bindings.len]bool,
    };
    pub const InnerParams = struct {
        freq: f32,
        note_on: bool,
    };

    const Voice = struct {
        down: bool,
        iq: zang.Notes(InnerParams).ImpulseQueue,
        osc: zang.Triggerable(zang.PulseOsc),
        flt: zang.Triggerable(zang.Filter),
        envelope: zang.Triggerable(zang.Envelope),
    };

    voices: [common.key_bindings.len]Voice,

    fn init() Polyphony {
        var self = Polyphony {
            .voices = undefined,
        };
        var i: usize = 0; while (i < common.key_bindings.len) : (i += 1) {
            self.voices[i] = Voice {
                .down = false,
                .iq = zang.Notes(InnerParams).ImpulseQueue.init(),
                .osc = zang.initTriggerable(zang.PulseOsc.init()),
                .flt = zang.initTriggerable(zang.Filter.init()),
                .envelope = zang.initTriggerable(zang.Envelope.init(zang.EnvParams {
                    .attack_duration = 0.01,
                    .decay_duration = 0.1,
                    .sustain_volume = 0.8,
                    .release_duration = 0.5,
                })),
            };
        }
        return self;
    }

    fn reset(self: *Polyphony) void {}

    fn paintSpan(self: *Polyphony, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const out = outputs[0];

        var i: usize = 0; while (i < common.key_bindings.len) : (i += 1) {
            if (params.note_held[i] != self.voices[i].down) {
                self.voices[i].iq.push(0, InnerParams {
                    .freq = A4 * common.key_bindings[i].rel_freq,
                    .note_on = params.note_held[i],
                });
                self.voices[i].down = params.note_held[i];
            }
        }

        for (self.voices) |*voice| {
            const impulses = voice.iq.consume();

            zang.zero(temps[0]);
            {
                var conv = zang.ParamsConverter(InnerParams, zang.PulseOsc.Params).init();
                for (conv.getPairs(impulses)) |*pair| {
                    pair.dest = zang.PulseOsc.Params {
                        .freq = pair.source.freq,
                        .colour = 0.3,
                    };
                }
                voice.osc.paintFromImpulses(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, conv.getImpulses());
            }
            zang.multiplyWithScalar(temps[0], 0.5);
            zang.zero(temps[1]);
            {
                var conv = zang.ParamsConverter(InnerParams, zang.Filter.Params).init();
                for (conv.getPairs(impulses)) |*pair| {
                    pair.dest = zang.Filter.Params {
                        .input = temps[0],
                        .filterType = .LowPass,
                        .cutoff = zang.cutoffFromFrequency(pair.source.freq * 8.0, sample_rate),
                        .resonance = 0.7,
                    };
                }
                voice.flt.paintFromImpulses(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, conv.getImpulses());
            }
            zang.zero(temps[0]);
            {
                var conv = zang.ParamsConverter(InnerParams, zang.Envelope.Params).init();
                voice.envelope.paintFromImpulses(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, conv.autoStructural(impulses));
            }
            zang.multiply(out, temps[0], temps[1]);
        }
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

const MyDecimatorParams = struct {
    bypass: bool,
};

pub const MainModule = struct {
    iq: zang.Notes(Polyphony.Params).ImpulseQueue,
    current_params: Polyphony.Params,
    polyphony: zang.Triggerable(Polyphony),
    dec: zang.Decimator,
    dec_mode: u32,

    pub fn init() MainModule {
        return MainModule{
            .iq = zang.Notes(Polyphony.Params).ImpulseQueue.init(),
            .current_params = Polyphony.Params {
                .note_held = [1]bool{false} ** common.key_bindings.len,
            },
            .polyphony = zang.initTriggerable(Polyphony.init()),
            .dec = zang.Decimator.init(),
            .dec_mode = 0,
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];
        const tmp2 = g_buffers.buf3[0..];

        zang.zero(out);

        const impulses = self.iq.consume();

        zang.zero(tmp2);
        self.polyphony.paintFromImpulses(sample_rate, [1][]f32{tmp2}, [2][]f32{tmp0, tmp1}, impulses);

        if (self.dec_mode > 0) {
            self.dec.paintSpan(sample_rate, [1][]f32{out}, [0][]f32{}, zang.Decimator.Params {
                .input = tmp2,
                .fake_sample_rate = switch (self.dec_mode) {
                    1 => f32(6000.0),
                    2 => f32(5000.0),
                    3 => f32(4000.0),
                    4 => f32(3000.0),
                    5 => f32(2000.0),
                    6 => f32(1000.0),
                    else => unreachable,
                },
            });
        } else {
            zang.addInto(out, tmp2);
        }

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (key == c.SDLK_SPACE and down) {
            self.dec_mode = (self.dec_mode + 1) % 7;
            return;
        }
        for (common.key_bindings) |kb, i| {
            if (kb.key == key) {
                self.current_params.note_held[i] = down;
                self.iq.push(impulse_frame, self.current_params);
            }
        }
    }
};
