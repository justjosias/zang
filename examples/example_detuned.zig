// in this example you can play a simple monophonic synth with the keyboard.
// there is a random warble added to the note frequencies, which was created
// using white noise and a low pass filter.
// also, you can press spacebar to cycle through a few modes (doesn't take
// effect until you press a new key):
//   0. wide warble, no echo
//   1. narrow warble, no echo
//   2. wide warble, echo
//   3. narrow warble, echo (here the warble does a good job of avoiding
//      constructive interference from the echo)

const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");
const StereoEchoes = @import("modules.zig").StereoEchoes;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

const A4 = 440.0;

pub const Instrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 3;
    pub const Params = struct {
        freq: f32,
        freq_warble: []const f32,
        note_on: bool,
    };

    dc: zang.DC,
    osc: zang.Oscillator,
    env: zang.Envelope,
    main_filter: zang.Filter,

    pub fn init() Instrument {
        return Instrument {
            .dc = zang.DC.init(),
            .osc = zang.Oscillator.init(),
            .env = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            }),
            .main_filter = zang.Filter.init(),
        };
    }

    pub fn reset(self: *Instrument) void {
        self.env.reset();
    }

    pub fn paint(self: *Instrument, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        var i: usize = 0; while (i < temps[0].len) : (i += 1) {
            temps[0][i] = params.freq * std.math.pow(f32, 2.0, params.freq_warble[i]);
        }
        // paint with oscillator into temps[1]
        zang.zero(temps[1]);
        self.osc.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Oscillator.Params {
            .waveform = .Sawtooth,
            .freq = zang.buffer(temps[0]),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });
        // combine with envelope
        zang.zero(temps[0]);
        self.env.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Envelope.Params {
            .note_on = params.note_on,
        });
        zang.zero(temps[2]);
        zang.multiply(temps[2], temps[1], temps[0]);
        // add main filter
        self.main_filter.paint(sample_rate, [1][]f32{outputs[0]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[2],
            .filterType = .LowPass,
            .cutoff = zang.constant(zang.cutoffFromFrequency(880.0, sample_rate)),
            // .cutoff = zang.constant(zang.cutoffFromFrequency(params.freq + 400.0, sample_rate)),
            .resonance = 0.8,
        });
        // volume boost
        zang.multiplyWithScalar(outputs[0], 1.5);
    }
};

pub const OuterInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 4;
    pub const Params = struct { freq: f32, note_on: bool, mode: u32 };

    noise: zang.Noise,
    noise_filter: zang.Filter,
    inner: Instrument,

    pub fn init() OuterInstrument {
        return OuterInstrument {
            .noise = zang.Noise.init(0),
            .noise_filter = zang.Filter.init(),
            .inner = Instrument.init(),
        };
    }

    pub fn reset(self: *OuterInstrument) void {
        self.inner.reset();
    }

    pub fn paint(self: *OuterInstrument, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        // temps[0] = filtered noise
        // note: filter frequency is set to 4hz. i wanted to go slower but
        // unfortunately at below 4, the filter degrades and the output
        // frequency slowly sinks to zero
        zang.zero(temps[1]);
        self.noise.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Noise.Params {});
        zang.zero(temps[0]);
        self.noise_filter.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[1],
            .filterType = .LowPass,
            .cutoff = zang.constant(zang.cutoffFromFrequency(4.0, sample_rate)),
            .resonance = 0.0,
        });

        if ((params.mode & 1) == 0) {
            zang.multiplyWithScalar(temps[0], 4.0);
        }

        self.inner.paint(sample_rate, outputs, [3][]f32{temps[1], temps[2], temps[3]}, Instrument.Params {
            .freq = params.freq,
            .freq_warble = temps[0],
            .note_on = params.note_on,
        });
    }
};

pub const MainModule = struct {
    pub const NumOutputs = 2;
    pub const NumTemps = 5;

    iq: zang.Notes(OuterInstrument.Params).ImpulseQueue,
    key: ?i32,
    outer: zang.Triggerable(OuterInstrument),
    echoes: StereoEchoes,
    mode: u32,

    pub fn init() MainModule {
        return MainModule {
            .iq = zang.Notes(OuterInstrument.Params).ImpulseQueue.init(),
            .key = null,
            .outer = zang.initTriggerable(OuterInstrument.init()),
            .echoes = StereoEchoes.init(),
            .mode = 0,
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        // FIXME - here's something missing in the API... what if i want to
        // pass some "global" params to paintFromImpulses? in other words,
        // saw that of the fields in OuterInstrument.Params, i only want to set
        // some of them in the impulse queue. others i just want to pass once,
        // here. for example i would pass the "mode" field.
        zang.zero(temps[0]);
        self.outer.paintFromImpulses(sample_rate, [1][]f32{temps[0]}, [4][]f32{temps[1], temps[2], temps[3], temps[4]}, self.iq.consume());

        if ((self.mode & 2) == 0) {
            // avoid the echo effect
            zang.addInto(outputs[0], temps[0]);
            zang.addInto(outputs[1], temps[0]);
            zang.zero(temps[0]);
        }

        self.echoes.paint(sample_rate, outputs, [4][]f32{temps[1], temps[2], temps[3], temps[4]}, StereoEchoes.Params {
            .input = temps[0],
            .feedback_volume = 0.6,
            .cutoff = 0.1,
        });
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (key == c.SDLK_SPACE and down) {
            self.mode = (self.mode + 1) & 3;
        }
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, OuterInstrument.Params {
                    .freq = A4 * rel_freq * 0.5,
                    .note_on = down,
                    // note: because i'm passing mode here, a change to mode
                    // take effect until you press a new key
                    .mode = self.mode,
                });
            }
        }
    }
};
