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
    c\\Play with the keyboard - a little melody is played
    c\\with each keypress. This demonstrates "notes within
    c\\notes".
;

const a4 = 440.0;

const InnerInstrument = struct {
    pub const num_outputs = 1;
    pub const num_temps = 2;
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

    fn paint(self: *InnerInstrument, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, note_id_changed: bool, params: Params) void {
        zang.zero(span, temps[0]);
        self.osc.paint(span, [1][]f32{temps[0]}, [0][]f32{}, zang.Oscillator.Params {
            .sample_rate = params.sample_rate,
            .waveform = .Sawtooth,
            .freq = zang.constant(params.freq),
            .phase = zang.constant(0.0),
            .color = 0.5,
        });
        zang.zero(span, temps[1]);
        self.env.paint(span, [1][]f32{temps[1]}, [0][]f32{}, note_id_changed, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack = zang.Envelope.Curve { .curve_type = .Cubed, .duration = 0.025 },
            .decay = zang.Envelope.Curve { .curve_type = .Cubed, .duration = 0.1 },
            .release = zang.Envelope.Curve { .curve_type = .Cubed, .duration = 0.15 },
            .sustain_volume = 0.5,
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
    pub const num_outputs = 1;
    pub const num_temps = 2;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    pub const BaseFrequency = a4 * note_frequencies.c4;

    tracker: zang.Notes(MyNoteParams).NoteTracker,
    instr: InnerInstrument,
    trigger: zang.Trigger(MyNoteParams),

    fn init() SubtrackPlayer {
        const SongEvent = zang.Notes(MyNoteParams).SongEvent;
        const f = note_frequencies;
        const t = 0.1;

        return SubtrackPlayer {
            .tracker = zang.Notes(MyNoteParams).NoteTracker.init([_]SongEvent {
                SongEvent { .t = 0.0 * t, .note_id = 1, .params = MyNoteParams { .freq = a4 * f.c4, .note_on = true }},
                SongEvent { .t = 1.0 * t, .note_id = 2, .params = MyNoteParams { .freq = a4 * f.ab3, .note_on = true }},
                SongEvent { .t = 2.0 * t, .note_id = 3, .params = MyNoteParams { .freq = a4 * f.g3, .note_on = true }},
                SongEvent { .t = 3.0 * t, .note_id = 4, .params = MyNoteParams { .freq = a4 * f.eb3, .note_on = true }},
                SongEvent { .t = 4.0 * t, .note_id = 5, .params = MyNoteParams { .freq = a4 * f.c3, .note_on = true }},
                SongEvent { .t = 5.0 * t, .note_id = 5, .params = MyNoteParams { .freq = a4 * f.c3, .note_on = false }},
            }),
            .instr = InnerInstrument.init(),
            .trigger = zang.Trigger(MyNoteParams).init(),
        };
    }

    fn paint(self: *SubtrackPlayer, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, note_id_changed: bool, params: Params) void {
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
    pub const num_outputs = 1;
    pub const num_temps = 2;

    key: ?i32,
    iq: zang.Notes(SubtrackPlayer.Params).ImpulseQueue,
    idgen: zang.IdGenerator,
    player: SubtrackPlayer,
    trigger: zang.Trigger(SubtrackPlayer.Params),

    pub fn init() MainModule {
        return MainModule {
            .key = null,
            .iq = zang.Notes(SubtrackPlayer.Params).ImpulseQueue.init(),
            .idgen = zang.IdGenerator.init(),
            .player = SubtrackPlayer.init(),
            .trigger = zang.Trigger(SubtrackPlayer.Params).init(),
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        var ctr = self.trigger.counter(span, self.iq.consume());
        while (self.trigger.next(&ctr)) |result| {
            self.player.paint(result.span, outputs, temps, result.note_id_changed, result.params);
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, self.idgen.nextId(), SubtrackPlayer.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .freq = a4 * rel_freq,
                    .note_on = down,
                });
            }
        }
    }
};
