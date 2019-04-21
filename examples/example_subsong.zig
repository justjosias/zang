// in this example a little melody plays every time you hit a key
// TODO - maybe add an envelope effect at the outer level, to demonstrate that
// the note events are nesting correctly

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
const SubtrackPlayer = struct {
    pub const NumTempBufs = 2;
    pub const BaseFrequency = note_frequencies.C4;

    tracker: zang.NoteTracker,
    osc: zang.Oscillator,
    osc_triggerable: zang.Triggerable(zang.Oscillator),
    env: zang.Envelope,
    env_triggerable: zang.Triggerable(zang.Envelope),

    fn init() SubtrackPlayer {
        const f = note_frequencies;

        return SubtrackPlayer{
            .tracker = zang.NoteTracker.init([]zang.SongNote {
                zang.SongNote{ .t = 0.0, .freq = f.C4 },
                zang.SongNote{ .t = 0.1, .freq = f.Ab3 },
                zang.SongNote{ .t = 0.2, .freq = f.G3 },
                zang.SongNote{ .t = 0.3, .freq = f.Eb3 },
                zang.SongNote{ .t = 0.4, .freq = f.C3 },
                zang.SongNote{ .t = 0.5, .freq = null },
            }),
            .osc = zang.Oscillator.init(.Sawtooth),
            .osc_triggerable = zang.Triggerable(zang.Oscillator).init(),
            .env = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 0.15,
            }),
            .env_triggerable = zang.Triggerable(zang.Envelope).init(),
        };
    }

    fn paint(self: *SubtrackPlayer, sample_rate: f32, out: []f32, note_on: bool, freq: f32, tmp: [NumTempBufs][]f32) void {
        const impulses = self.tracker.getImpulses(sample_rate, out.len, freq / BaseFrequency);

        zang.zero(tmp[0]);
        self.osc_triggerable.paintFromImpulses(&self.osc, sample_rate, tmp[0], impulses, [0][]f32{});
        zang.zero(tmp[1]);
        self.env_triggerable.paintFromImpulses(&self.env, sample_rate, tmp[1], impulses, [0][]f32{});
        zang.multiply(out, tmp[0], tmp[1]);
    }

    fn reset(self: *SubtrackPlayer) void {
        // FIXME - i think something's still not right. i hear clicking sometimes when you press notes
        self.tracker.reset();
        self.osc.reset();
        self.env.reset();
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    iq: zang.ImpulseQueue,
    key: ?i32,
    subtrack_player: SubtrackPlayer,
    subtrack_triggerable: zang.Triggerable(SubtrackPlayer),

    pub fn init() MainModule {
        return MainModule{
            .iq = zang.ImpulseQueue.init(),
            .key = null,
            .subtrack_player = SubtrackPlayer.init(),
            .subtrack_triggerable = zang.Triggerable(SubtrackPlayer).init(),
        };
    }

    pub fn paint(self: *MainModule) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];

        zang.zero(out);

        const impulses = self.iq.consume();

        self.subtrack_triggerable.paintFromImpulses(&self.subtrack_player, AUDIO_SAMPLE_RATE, out, impulses, [2][]f32{tmp0, tmp1});

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool) ?common.KeyEvent {
        const f = note_frequencies;

        if (switch (key) {
            c.SDLK_a => f.C4,
            c.SDLK_w => f.Cs4,
            c.SDLK_s => f.D4,
            c.SDLK_e => f.Ds4,
            c.SDLK_d => f.E4,
            c.SDLK_f => f.F4,
            c.SDLK_t => f.Fs4,
            c.SDLK_g => f.G4,
            c.SDLK_y => f.Gs4,
            c.SDLK_h => f.A4,
            c.SDLK_u => f.As4,
            c.SDLK_j => f.B4,
            c.SDLK_k => f.C5,
            else => null,
        }) |freq| {
            if (down) {
                self.key = key;

                return common.KeyEvent {
                    .iq = &self.iq,
                    .freq = freq,
                };
            } else {
                if (if (self.key) |nh| nh == key else false) {
                    self.key = null;

                    return common.KeyEvent {
                        .iq = &self.iq,
                        .freq = null,
                    };
                }
            }
        }

        return null;
    }
};
