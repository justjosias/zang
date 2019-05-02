// in this example a little melody plays every time you hit a key
// TODO - maybe add an envelope effect at the outer level, to demonstrate that
// the note events are nesting correctly

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

const MyNoteParams = SubtrackPlayer.Params;
const MyNotes = zang.Notes(MyNoteParams);

// an example of a custom "module"
const SubtrackPlayer = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct {
        freq: f32,
        note_on: bool,
    };
    pub const BaseFrequency = A4 * note_frequencies.C4;

    tracker: MyNotes.NoteTracker,
    osc: zang.Triggerable(zang.Oscillator),
    env: zang.Triggerable(zang.Envelope),

    fn init() SubtrackPlayer {
        const f = note_frequencies;

        return SubtrackPlayer{
            .tracker = MyNotes.NoteTracker.init([]MyNotes.SongNote {
                MyNotes.SongNote{ .t = 0.0, .params = MyNoteParams{ .freq = A4 * f.C4, .note_on = true }},
                MyNotes.SongNote{ .t = 0.1, .params = MyNoteParams{ .freq = A4 * f.Ab3, .note_on = true }},
                MyNotes.SongNote{ .t = 0.2, .params = MyNoteParams{ .freq = A4 * f.G3, .note_on = true }},
                MyNotes.SongNote{ .t = 0.3, .params = MyNoteParams{ .freq = A4 * f.Eb3, .note_on = true }},
                MyNotes.SongNote{ .t = 0.4, .params = MyNoteParams{ .freq = A4 * f.C3, .note_on = true }},
                MyNotes.SongNote{ .t = 0.5, .params = MyNoteParams{ .freq = A4 * f.C3, .note_on = false }},
            }),
            .osc = zang.initTriggerable(zang.Oscillator.init()),
            .env = zang.initTriggerable(zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 0.15,
            })),
        };
    }

    fn reset(self: *SubtrackPlayer) void {
        self.tracker.reset();
        self.osc.reset();
        self.env.reset();
    }

    fn paint(self: *SubtrackPlayer, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const out = outputs[0];
        const impulses = self.tracker.getImpulses(sample_rate, out.len);

        zang.zero(temps[0]);
        {
            var conv = zang.ParamsConverter(MyNoteParams, zang.Oscillator.Params).init();
            for (conv.getPairs(impulses)) |*pair| {
                pair.dest = zang.Oscillator.Params {
                    .waveform = .Sawtooth,
                    .freq = pair.source.freq * params.freq / BaseFrequency,
                    .colour = 0.5,
                };
            }
            self.osc.paintFromImpulses(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, conv.getImpulses());
        }
        zang.zero(temps[1]);
        {
            var conv = zang.ParamsConverter(MyNoteParams, zang.Envelope.Params).init();
            self.env.paintFromImpulses(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, conv.autoStructural(impulses));
        }
        zang.multiply(out, temps[0], temps[1]);
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    iq: MyNotes.ImpulseQueue,
    key: ?i32,
    subtrack_player: zang.Triggerable(SubtrackPlayer),

    pub fn init() MainModule {
        return MainModule{
            .iq = MyNotes.ImpulseQueue.init(),
            .key = null,
            .subtrack_player = zang.initTriggerable(SubtrackPlayer.init()),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];

        zang.zero(out);

        const impulses = self.iq.consume();

        self.subtrack_player.paintFromImpulses(sample_rate, [1][]f32{out}, [2][]f32{tmp0, tmp1}, impulses);

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, MyNoteParams { .freq = A4 * rel_freq, .note_on = down });
            }
        }
    }
};
