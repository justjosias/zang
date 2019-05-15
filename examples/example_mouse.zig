const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");
const PhaseModOscillator = @import("modules.zig").PhaseModOscillator;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_mouse
    c\\
    c\\Play a phase-modulation instrument with
    c\\the keyboard, while controlling the
    c\\sound parameters with the mouse
    c\\position.
    c\\
    c\\Press spacebar to toggle between
    c\\relative (the default) and absolute
    c\\modulator frequency.
;

const A4 = 440.0;

const PMOscInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 4;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
        relative: bool,
        ratio: []const f32,
        multiplier: []const f32,
    };

    osc: PhaseModOscillator,
    env: zang.Envelope,

    pub fn init() PMOscInstrument {
        return PMOscInstrument {
            .osc = PhaseModOscillator.init(),
            .env = zang.Envelope.init(),
        };
    }

    pub fn paint(self: *PMOscInstrument, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, note_id_changed: bool, params: Params) void {
        zang.zero(span, temps[0]);
        self.osc.paint(span, [1][]f32{temps[0]}, [3][]f32{temps[1], temps[2], temps[3]}, PhaseModOscillator.Params {
            .sample_rate = params.sample_rate,
            .freq = params.freq,
            .relative = params.relative,
            .ratio = zang.buffer(params.ratio),
            .multiplier = zang.buffer(params.multiplier),
        });
        zang.zero(span, temps[1]);
        self.env.paint(span, [1][]f32{temps[1]}, [0][]f32{}, note_id_changed, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack_duration = 0.025,
            .decay_duration = 0.1,
            .sustain_volume = 0.5,
            .release_duration = 1.0,
            .note_on = params.note_on,
        });
        zang.multiply(span, outputs[0], temps[0], temps[1]);
    }
};

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 6;

    const Instr = struct {
        const Params = struct { freq: f32, note_on: bool };

        iq: zang.Notes(Params).ImpulseQueue,
        mod: PMOscInstrument,
        trig: zang.Trigger(Params),
    };

    const Porta = struct {
        const Params = struct { value: f32, note_on: bool };

        iq: zang.Notes(Params).ImpulseQueue,
        mod: zang.Portamento,
        trig: zang.Trigger(Params),
    };

    key: ?i32,
    first: bool,
    mode: u32,
    mode_iq: zang.Notes(u32).ImpulseQueue,
    instr: Instr,
    ratio: Porta,
    multiplier: Porta,

    pub fn init() MainModule {
        return MainModule {
            .key = null,
            .first = true,
            .mode = 0,
            .mode_iq = zang.Notes(u32).ImpulseQueue.init(),
            .instr = Instr {
                .iq = zang.Notes(Instr.Params).ImpulseQueue.init(),
                .mod = PMOscInstrument.init(),
                .trig = zang.Trigger(Instr.Params).init(),
            },
            .ratio = Porta {
                .iq = zang.Notes(Porta.Params).ImpulseQueue.init(),
                .mod = zang.Portamento.init(),
                .trig = zang.Trigger(Porta.Params).init(),
            },
            .multiplier = Porta {
                .iq = zang.Notes(Porta.Params).ImpulseQueue.init(),
                .mod = zang.Portamento.init(),
                .trig = zang.Trigger(Porta.Params).init(),
            },
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        if (self.first) {
            self.first = false;
            self.mode_iq.push(0, self.mode);
        }
        // ratio
        zang.zero(span, temps[0]);
        {
            var ctr = self.ratio.trig.counter(span, self.ratio.iq.consume());
            while (self.ratio.trig.next(&ctr)) |result| {
                self.ratio.mod.paint(result.span, [1][]f32{temps[0]}, [0][]f32{}, zang.Portamento.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .mode = .CatchUp,
                    .velocity = 8.0,
                    .value = switch (self.mode) {
                        0 => result.params.value * 4.0,
                        else => result.params.value * 880.0,
                    },
                    .note_on = result.params.note_on,
                });
            }
        }
        // multiplier
        zang.zero(span, temps[1]);
        {
            var ctr = self.multiplier.trig.counter(span, self.multiplier.iq.consume());
            while (self.multiplier.trig.next(&ctr)) |result| {
                self.multiplier.mod.paint(result.span, [1][]f32{temps[1]}, [0][]f32{}, zang.Portamento.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .mode = .CatchUp,
                    .velocity = 8.0,
                    .value = result.params.value * 2.0,
                    .note_on = result.params.note_on,
                });
            }
        }
        // instr
        {
            var ctr = self.instr.trig.counter(span, self.instr.iq.consume());
            while (self.instr.trig.next(&ctr)) |result| {
                self.instr.mod.paint(result.span, outputs, [4][]f32{temps[2], temps[3], temps[4], temps[5]}, result.note_id_changed, PMOscInstrument.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .freq = result.params.freq,
                    .note_on = result.params.note_on,
                    .relative = self.mode == 0,
                    .ratio = temps[0],
                    .multiplier = temps[1],
                });
            }
        }
    }

    pub fn mouseEvent(self: *MainModule, x: f32, y: f32, impulse_frame: usize) void {
        self.ratio.iq.push(impulse_frame, Porta.Params { .value = x, .note_on = true });
        self.multiplier.iq.push(impulse_frame, Porta.Params { .value = y, .note_on = true });
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (key == c.SDLK_SPACE and down) {
            self.mode = (self.mode + 1) % 2;
            self.mode_iq.push(impulse_frame, self.mode);
        }
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.instr.iq.push(impulse_frame, Instr.Params {
                    .freq = A4 * rel_freq,
                    .note_on = down,
                });
            }
        }
    }
};
