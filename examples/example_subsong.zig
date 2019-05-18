// TODO - maybe add an envelope effect at the outer level, to demonstrate that
// the note events are nesting correctly

const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/c.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_subsong
    c\\
    c\\Play with the keyboard - a little
    c\\melody is played with each keypress.
    c\\This demonstrates "notes within notes".
;

const A4 = 440.0;

const InnerInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    osc: zang.Oscillator,
    env: zang.Envelope,

    fn init() InnerInstrument {
        return InnerInstrument {
            .osc = zang.Oscillator.init(),
            .env = zang.Envelope.init(),
        };
    }

    fn paint(self: *InnerInstrument, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, note_id_changed: bool, params: Params) void {
        zang.zero(span, temps[0]);
        self.osc.paint(span, [1][]f32{temps[0]}, [0][]f32{}, zang.Oscillator.Params {
            .sample_rate = params.sample_rate,
            .waveform = .Sawtooth,
            .freq = zang.constant(params.freq),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });
        zang.zero(span, temps[1]);
        self.env.paint(span, [1][]f32{temps[1]}, [0][]f32{}, note_id_changed, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack_duration = 0.025,
            .decay_duration = 0.1,
            .sustain_volume = 0.5,
            .release_duration = 0.15,
            .note_on = params.note_on,
        });
        zang.multiply(span, outputs[0], temps[0], temps[1]);
    }
};

const MyNoteParams = struct {
    freq: f32,
    note_on: bool,
};

// an example of a custom "module"
const SubtrackPlayer = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    pub const BaseFrequency = A4 * note_frequencies.C4;

    tracker: zang.Notes(MyNoteParams).NoteTracker,
    instr: InnerInstrument,
    trigger: zang.Trigger(MyNoteParams),

    fn init() SubtrackPlayer {
        const SongNote = zang.Notes(MyNoteParams).SongNote;
        const f = note_frequencies;
        const t = 0.1;

        return SubtrackPlayer {
            .tracker = zang.Notes(MyNoteParams).NoteTracker.init([]SongNote {
                SongNote { .t = 0.0 * t, .params = MyNoteParams { .freq = A4 * f.C4, .note_on = true }},
                SongNote { .t = 1.0 * t, .params = MyNoteParams { .freq = A4 * f.Ab3, .note_on = true }},
                SongNote { .t = 2.0 * t, .params = MyNoteParams { .freq = A4 * f.G3, .note_on = true }},
                SongNote { .t = 3.0 * t, .params = MyNoteParams { .freq = A4 * f.Eb3, .note_on = true }},
                SongNote { .t = 4.0 * t, .params = MyNoteParams { .freq = A4 * f.C3, .note_on = true }},
                SongNote { .t = 5.0 * t, .params = MyNoteParams { .freq = A4 * f.C3, .note_on = false }},
            }),
            .instr = InnerInstrument.init(),
            .trigger = zang.Trigger(MyNoteParams).init(),
        };
    }

    fn paint(self: *SubtrackPlayer, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, note_id_changed: bool, params: Params) void {
        if (params.note_on and note_id_changed) {
            self.tracker.reset();
            self.trigger.reset();
        }

        var ctr = self.trigger.counter(span, self.tracker.consume(params.sample_rate, span.end - span.start));
        while (self.trigger.next(&ctr)) |result| {
            self.instr.paint(result.span, outputs, temps, (params.note_on and note_id_changed) or result.note_id_changed, InnerInstrument.Params {
                .sample_rate = params.sample_rate,
                .freq = result.params.freq * params.freq / BaseFrequency,
                .note_on = result.params.note_on,
            });
        }
    }
};

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;

    key: ?i32,
    iq: zang.Notes(SubtrackPlayer.Params).ImpulseQueue,
    player: SubtrackPlayer,
    trigger: zang.Trigger(SubtrackPlayer.Params),

    pub fn init() MainModule {
        return MainModule {
            .key = null,
            .iq = zang.Notes(SubtrackPlayer.Params).ImpulseQueue.init(),
            .player = SubtrackPlayer.init(),
            .trigger = zang.Trigger(SubtrackPlayer.Params).init(),
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        var ctr = self.trigger.counter(span, self.iq.consume());
        while (self.trigger.next(&ctr)) |result| {
            self.player.paint(result.span, outputs, temps, result.note_id_changed, result.params);
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, SubtrackPlayer.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .freq = A4 * rel_freq,
                    .note_on = down,
                });
            }
        }
    }
};
