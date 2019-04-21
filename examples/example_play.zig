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

// an example of a custom "module"
const PulseModOscillator = struct {
    pub const NumTempBufs = 3;

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
            .carrier = zang.Oscillator.init(.Sine),
            .modulator = zang.Oscillator.init(.Sine),
            .ratio = ratio,
            .multiplier = multiplier,
        };
    }

    fn reset(self: *PulseModOscillator) void {}

    fn paint(self: *PulseModOscillator, sample_rate: f32, out: []f32, note_on: bool, freq: f32, tmp: [3][]f32) void {
        zang.set(tmp[0], freq);
        zang.set(tmp[1], freq * self.ratio);
        zang.zero(tmp[2]);
        self.modulator.paintControlledFrequency(sample_rate, tmp[2], tmp[1]);
        zang.zero(tmp[1]);
        zang.multiplyScalar(tmp[1], tmp[2], self.multiplier);
        self.carrier.paintControlledPhaseAndFrequency(sample_rate, out, tmp[1], tmp[0]);
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
    buf4: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

const NoteParams = struct {
    iq: *zang.ImpulseQueue,
    nh: *?i32,
    freq: f32,
};

pub const MainModule = struct {
    iq0: zang.ImpulseQueue,
    key0: ?i32,
    osc0: PulseModOscillator,
    osc0_trigger: zang.Trigger(PulseModOscillator),
    env0: zang.Envelope,
    env0_trigger: zang.Trigger(zang.Envelope),

    iq1: zang.ImpulseQueue,
    key1: ?i32,
    osc1: zang.Oscillator,
    osc1_trigger: zang.Trigger(zang.Oscillator),
    env1: zang.Envelope,
    env1_trigger: zang.Trigger(zang.Envelope),

    flt: zang.Filter,

    pub fn init() MainModule {
        const cutoff = zang.cutoffFromFrequency(note_frequencies.C5, AUDIO_SAMPLE_RATE);

        return MainModule{
            .iq0 = zang.ImpulseQueue.init(),
            .key0 = null,
            .osc0 = PulseModOscillator.init(1.0, 1.5),
            .osc0_trigger = zang.Trigger(PulseModOscillator).init(),
            .env0 = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            }),
            .env0_trigger = zang.Trigger(zang.Envelope).init(),
            .iq1 = zang.ImpulseQueue.init(),
            .key1 = null,
            .osc1 = zang.Oscillator.init(.Sawtooth),
            .osc1_trigger = zang.Trigger(zang.Oscillator).init(),
            .env1 = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            }),
            .env1_trigger = zang.Trigger(zang.Envelope).init(),
            .flt = zang.Filter.init(.LowPass, cutoff, 0.7),
        };
    }

    pub fn paint(self: *MainModule) [AUDIO_CHANNELS][]const f32 {
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
            self.osc0_trigger.paintFromImpulses(&self.osc0, AUDIO_SAMPLE_RATE, tmp0, impulses, [3][]f32{tmp1, tmp2, tmp3});
            zang.zero(tmp1);
            self.env0_trigger.paintFromImpulses(&self.env0, AUDIO_SAMPLE_RATE, tmp1, impulses, [0][]f32{});
            zang.multiply(out, tmp0, tmp1);
        }

        {
            // sawtooth wave with resonant low pass filter, with ADSR envelope
            const impulses = self.iq1.consume();

            zang.zero(tmp3);
            self.osc1_trigger.paintFromImpulses(&self.osc1, AUDIO_SAMPLE_RATE, tmp3, impulses, [0][]f32{});
            zang.zero(tmp0);
            zang.multiplyScalar(tmp0, tmp3, 2.5); // boost sawtooth volume
            zang.zero(tmp1);
            self.env1_trigger.paintFromImpulses(&self.env1, AUDIO_SAMPLE_RATE, tmp1, impulses, [0][]f32{});
            zang.zero(tmp2);
            zang.multiply(tmp2, tmp0, tmp1);
            self.flt.paint(out, tmp2);
        }

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool) ?common.KeyEvent {
        const f = note_frequencies;

        if (switch (key) {
            c.SDLK_SPACE => NoteParams{ .iq = &self.iq1, .nh = &self.key1, .freq = f.C4 / 4.0 },
            c.SDLK_a => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.C4 },
            c.SDLK_w => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.Cs4 },
            c.SDLK_s => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.D4 },
            c.SDLK_e => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.Ds4 },
            c.SDLK_d => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.E4 },
            c.SDLK_f => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.F4 },
            c.SDLK_t => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.Fs4 },
            c.SDLK_g => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.G4 },
            c.SDLK_y => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.Gs4 },
            c.SDLK_h => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.A4 },
            c.SDLK_u => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.As4 },
            c.SDLK_j => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.B4 },
            c.SDLK_k => NoteParams{ .iq = &self.iq0, .nh = &self.key0, .freq = f.C5 },
            else => null,
        }) |params| {
            if (down) {
                params.nh.* = key;

                return common.KeyEvent{
                    .iq = params.iq,
                    .freq = params.freq,
                };
            } else {
                if (if (params.nh.*) |nh| nh == key else false) {
                    params.nh.* = null;

                    return common.KeyEvent{
                        .iq = params.iq,
                        .freq = null,
                    };
                }
            }
        }

        return null;
    }
};
