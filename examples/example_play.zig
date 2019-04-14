// in this example you can play a simple monophonic synth with the keyboard

const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

// an example of a custom "module"
const PulseModOscillator = struct {
    carrier: zang.Oscillator,
    modulator: zang.Oscillator,
    dc: zang.DC,
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
            .dc = zang.DC.init(),
            .ratio = ratio,
            .multiplier = multiplier,
        };
    }

    // TODO - can i add a plain 'paint' function?
    // will need to add 'frequency' as a field to the PulseModOscillator.
    // can i do this without too much duplication with paintFromImpulses?
    // (in other words can i have paintFromImpulses be some simple calls into
    // paint?)

    fn paintFromImpulses(
        self: *PulseModOscillator,
        sample_rate: u32,
        out: []f32,
        track: []const zang.Impulse,
        tmp0: []f32,
        tmp1: []f32,
        tmp2: []f32,
        frame_index: usize,
    ) void {
        std.debug.assert(out.len == tmp0.len);
        std.debug.assert(out.len == tmp1.len);
        std.debug.assert(out.len == tmp2.len);

        zang.zero(tmp0);
        zang.zero(tmp1);
        self.dc.paintFrequencyFromImpulses(tmp0, track, frame_index);
        zang.multiplyScalar(tmp1, tmp0, self.ratio);
        zang.zero(tmp2);
        self.modulator.paintControlledFrequency(sample_rate, tmp2, tmp1);
        zang.zero(tmp1);
        zang.multiplyScalar(tmp1, tmp2, self.multiplier);
        self.carrier.paintControlledPhaseAndFrequency(sample_rate, out, tmp1, tmp0);
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
    buf4: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

var g_note_held0: ?i32 = null;
var g_note_held1: ?i32 = null;

const NoteParams = struct {
    iq: *zang.ImpulseQueue,
    nh: *?i32,
    freq: f32,
};

pub const MainModule = struct {
    frame_index: usize,

    iq0: zang.ImpulseQueue,
    osc0: PulseModOscillator,
    env0: zang.Envelope,

    iq1: zang.ImpulseQueue,
    osc1: zang.Oscillator,
    env1: zang.Envelope,

    flt: zang.Filter,

    pub fn init() MainModule {
        return MainModule{
            .frame_index = 0,
            .iq0 = zang.ImpulseQueue.init(),
            .osc0 = PulseModOscillator.init(1.0, 1.5),
            .env0 = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            }),
            .iq1 = zang.ImpulseQueue.init(),
            .osc1 = zang.Oscillator.init(.Sawtooth),
            .env1 = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            }),
            .flt = zang.Filter.init(.LowPass, zang.cutoffFromFrequency(zang.note_frequencies.C5, AUDIO_SAMPLE_RATE), 0.7),
        };
    }

    pub fn paint(self: *MainModule) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];
        const tmp2 = g_buffers.buf3[0..];
        const tmp3 = g_buffers.buf4[0..];

        zang.zero(out);

        if (!self.iq0.isEmpty()) {
            // use ADSR envelope with pulse mod oscillator
            zang.zero(tmp0);
            self.osc0.paintFromImpulses(AUDIO_SAMPLE_RATE, tmp0, self.iq0.getImpulses(), tmp1, tmp2, tmp3, self.frame_index);
            zang.zero(tmp1);
            self.env0.paintFromImpulses(AUDIO_SAMPLE_RATE, tmp1, self.iq0.getImpulses(), self.frame_index);
            zang.multiply(out, tmp0, tmp1);
        }

        if (!self.iq1.isEmpty()) {
            // sawtooth wave with resonant low pass filter
            zang.zero(tmp3);
            self.osc1.paintFromImpulses(AUDIO_SAMPLE_RATE, tmp3, self.iq1.getImpulses(), self.frame_index, null, true);
            zang.zero(tmp0);
            zang.multiplyScalar(tmp0, tmp3, 2.5); // sawtooth volume
            zang.zero(tmp1);
            self.env1.paintFromImpulses(AUDIO_SAMPLE_RATE, tmp1, self.iq1.getImpulses(), self.frame_index);
            zang.zero(tmp2);
            zang.multiply(tmp2, tmp0, tmp1);
            self.flt.paint(out, tmp2);
        }

        self.iq0.flush(self.frame_index, out.len);
        self.iq1.flush(self.frame_index, out.len);

        self.frame_index += out.len;

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool) ?common.KeyEvent {
        const f = zang.note_frequencies;

        if (switch (key) {
            c.SDLK_SPACE => NoteParams{ .iq = &self.iq1, .nh = &g_note_held1, .freq = f.C4 / 4.0 },
            c.SDLK_a => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.C4 },
            c.SDLK_w => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.Cs4 },
            c.SDLK_s => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.D4 },
            c.SDLK_e => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.Ds4 },
            c.SDLK_d => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.E4 },
            c.SDLK_f => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.F4 },
            c.SDLK_t => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.Fs4 },
            c.SDLK_g => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.G4 },
            c.SDLK_y => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.Gs4 },
            c.SDLK_h => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.A4 },
            c.SDLK_u => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.As4 },
            c.SDLK_j => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.B4 },
            c.SDLK_k => NoteParams{ .iq = &self.iq0, .nh = &g_note_held0, .freq = f.C5 },
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
