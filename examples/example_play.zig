// in this example you can play a simple monophonic synth with the keyboard

const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet").NoteFrequencies(440.0);
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

const MyNoteParams = PulseModOscillator.Params;
const MyNotes = zang.Notes(MyNoteParams);

// an example of a custom "module"
const PulseModOscillator = struct {
    pub const NumOutputs = 1;
    pub const NumInputs = 0;
    pub const NumTemps = 3;
    pub const Params = struct {
        freq: f32,
        note_on: bool,
    };

    carrier: zang.Oscillator,
    modulator: zang.Oscillator,
    // ratio: the carrier oscillator will use whatever frequency you give the
    // PulseModOscillator. the modulator oscillator will multiply the frequency
    // by this ratio. for example, a ratio of 0.5 means that the modulator
    // oscillator will always play at half the frequency of the carrier
    // oscillator
    ratio: f32,
    // multiplier: the modulator oscillator's output is multiplied by this
    // before it is fed in to the phase input of the carrier oscillator.
    multiplier: f32,

    fn init(ratio: f32, multiplier: f32) PulseModOscillator {
        return PulseModOscillator{
            .carrier = zang.Oscillator.init(),
            .modulator = zang.Oscillator.init(),
            .ratio = ratio,
            .multiplier = multiplier,
        };
    }

    fn reset(self: *PulseModOscillator) void {}

    fn paintSpan(self: *PulseModOscillator, sample_rate: f32, outputs: [NumOutputs][]f32, inputs: [NumInputs][]f32, temps: [NumTemps][]f32, params: MyNoteParams) void {
        const out = outputs[0];

        zang.set(temps[0], params.freq);
        zang.set(temps[1], params.freq * self.ratio);
        zang.zero(temps[2]);
        self.modulator.paintControlledFrequency(sample_rate, temps[2], .Sine, temps[1], 0.5);
        zang.zero(temps[1]);
        zang.multiplyScalar(temps[1], temps[2], self.multiplier);
        self.carrier.paintControlledPhaseAndFrequency(sample_rate, out, .Sine, temps[1], temps[0], 0.5);
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
    buf4: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    iq0: MyNotes.ImpulseQueue,
    key0: ?i32,
    osc0: zang.Triggerable(PulseModOscillator),
    env0: zang.Triggerable(zang.Envelope),

    iq1: MyNotes.ImpulseQueue,
    osc1: zang.Triggerable(zang.Oscillator),
    env1: zang.Triggerable(zang.Envelope),

    flt: zang.Triggerable(zang.Filter),

    pub fn init() MainModule {
        return MainModule{
            .iq0 = MyNotes.ImpulseQueue.init(),
            .key0 = null,
            .osc0 = zang.initTriggerable(PulseModOscillator.init(1.0, 1.5)),
            .env0 = zang.initTriggerable(zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            })),
            .iq1 = MyNotes.ImpulseQueue.init(),
            .osc1 = zang.initTriggerable(zang.Oscillator.init()),
            .env1 = zang.initTriggerable(zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            })),
            .flt = zang.initTriggerable(zang.Filter.init()),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];
        const tmp2 = g_buffers.buf3[0..];
        const tmp3 = g_buffers.buf4[0..];

        zang.zero(out);

        {
            // pulse mod oscillator, with ADSR envelope
            const impulses = self.iq0.consume();

            zang.zero(tmp0);
            self.osc0.paintFromImpulses(sample_rate, [1][]f32{tmp0}, [0][]f32{}, [3][]f32{tmp1, tmp2, tmp3}, impulses);
            zang.zero(tmp1);
            {
                var conv = zang.ParamsConverter(MyNoteParams, zang.Envelope.Params).init();
                self.env0.paintFromImpulses(sample_rate, [1][]f32{tmp1}, [0][]f32{}, [0][]f32{}, conv.autoStructural(impulses));
            }
            zang.multiply(out, tmp0, tmp1);
        }

        {
            // sawtooth wave with resonant low pass filter, with ADSR envelope
            const impulses = self.iq1.consume();

            zang.zero(tmp3);
            {
                var conv = zang.ParamsConverter(MyNoteParams, zang.Oscillator.Params).init();
                for (conv.getPairs(impulses)) |*pair| {
                    pair.dest = zang.Oscillator.Params {
                        .waveform = .Sawtooth,
                        .freq = pair.source.freq,
                        .colour = 0.5,
                    };
                }
                self.osc1.paintFromImpulses(sample_rate, [1][]f32{tmp3}, [0][]f32{}, [0][]f32{}, conv.getImpulses());
            }
            zang.zero(tmp0);
            zang.multiplyScalar(tmp0, tmp3, 2.5); // boost sawtooth volume
            zang.zero(tmp1);
            {
                var conv = zang.ParamsConverter(MyNoteParams, zang.Envelope.Params).init();
                self.env1.paintFromImpulses(sample_rate, [1][]f32{tmp1}, [0][]f32{}, [0][]f32{}, conv.autoStructural(impulses));
            }
            zang.zero(tmp2);
            zang.multiply(tmp2, tmp0, tmp1);
            {
                var conv = zang.ParamsConverter(MyNoteParams, zang.Filter.Params).init();
                for (conv.getPairs(impulses)) |*pair| {
                    pair.dest = zang.Filter.Params {
                        .filterType = .LowPass,
                        .cutoff = zang.cutoffFromFrequency(note_frequencies.C5, sample_rate),
                        .resonance = 0.7,
                    };
                }
                self.flt.paintFromImpulses(sample_rate, [1][]f32{out}, [1][]f32{tmp2}, [0][]f32{}, conv.getImpulses());
            }
        }

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (key == c.SDLK_SPACE) {
            self.iq1.push(impulse_frame, MyNoteParams {
                .freq = note_frequencies.C4 / 4.0,
                .note_on = down,
            });
        } else if (common.freqForKey(key)) |freq| {
            if (down or (if (self.key0) |nh| nh == key else false)) {
                self.key0 = if (down) key else null;
                self.iq0.push(impulse_frame, MyNoteParams {
                    .freq = freq,
                    .note_on = down,
                });
            }
        }
    }
};
