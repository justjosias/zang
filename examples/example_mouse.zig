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

    pub fn reset(self: *PMOscInstrument) void {
        self.osc.reset();
        self.env.reset();
    }

    pub fn paint(self: *PMOscInstrument, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        zang.zero(temps[0]);
        self.osc.paint(sample_rate, [1][]f32{temps[0]}, [3][]f32{temps[1], temps[2], temps[3]}, PhaseModOscillator.Params {
            .freq = params.freq,
            .relative = params.relative,
            .ratio = zang.buffer(params.ratio),
            .multiplier = zang.buffer(params.multiplier),
        });
        zang.zero(temps[1]);
        self.env.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Envelope.Params {
            .attack_duration = 0.025,
            .decay_duration = 0.1,
            .sustain_volume = 0.5,
            .release_duration = 1.0,
            .note_on = params.note_on,
        });
        zang.multiply(outputs[0], temps[0], temps[1]);
    }
};

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 6;

    const NoteParams = struct {
        freq: f32,
        note_on: bool,
    };

    iq: zang.Notes(NoteParams).ImpulseQueue,
    key: ?i32,
    instr: zang.Triggerable(PMOscInstrument),
    ratio_iq: zang.Notes(zang.Portamento.Params).ImpulseQueue,
    multiplier_iq: zang.Notes(zang.Portamento.Params).ImpulseQueue,
    ratio_portamento: zang.Triggerable(zang.Portamento),
    multiplier_portamento: zang.Triggerable(zang.Portamento),
    mode: u32,

    pub fn init() MainModule {
        return MainModule {
            .iq = zang.Notes(NoteParams).ImpulseQueue.init(),
            .key = null,
            .instr = zang.initTriggerable(PMOscInstrument.init()),
            .ratio_iq = zang.Notes(zang.Portamento.Params).ImpulseQueue.init(),
            .multiplier_iq = zang.Notes(zang.Portamento.Params).ImpulseQueue.init(),
            .ratio_portamento = zang.initTriggerable(zang.Portamento.init()),
            .multiplier_portamento = zang.initTriggerable(zang.Portamento.init()),
            .mode = 0,
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        zang.zero(temps[0]);
        self.ratio_portamento.paintFromImpulses(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, self.ratio_iq.consume());

        zang.zero(temps[1]);
        self.multiplier_portamento.paintFromImpulses(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, self.multiplier_iq.consume());

        // create a new list of impulses combining multiple sources
        // FIXME - see https://github.com/dbandstra/zang/issues/18
        var impulses: [33]zang.Notes(PMOscInstrument.Params).Impulse = undefined;
        var num_impulses: usize = 0;
        for (self.iq.consume()) |impulse| {
            impulses[num_impulses] = zang.Notes(PMOscInstrument.Params).Impulse {
                .frame = impulse.frame,
                .note = zang.Notes(PMOscInstrument.Params).NoteSpanNote {
                    .id = impulse.note.id,
                    .params = PMOscInstrument.Params {
                        .freq = impulse.note.params.freq,
                        .note_on = impulse.note.params.note_on,
                        .relative = self.mode == 0,
                        .ratio = temps[0],
                        .multiplier = temps[1],
                    },
                },
            };
            num_impulses += 1;
        }
        self.instr.paintFromImpulses(sample_rate, outputs, [4][]f32{temps[2], temps[3], temps[4], temps[5]}, impulses[0..num_impulses]);
    }

    pub fn mouseEvent(self: *MainModule, x: f32, y: f32, impulse_frame: usize) void {
        // use portamentos to smooth out the mouse motion
        self.ratio_iq.push(impulse_frame, zang.Portamento.Params {
            .mode = .CatchUp,
            .velocity = 8.0,
            .value = switch (self.mode) {
                0 => x * 4.0,
                else => x * 880.0,
            },
            .note_on = true,
        });
        self.multiplier_iq.push(impulse_frame, zang.Portamento.Params {
            .mode = .CatchUp,
            .velocity = 8.0,
            .value = y * 2.0,
            .note_on = true,
        });
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (key == c.SDLK_SPACE and down) {
            self.mode = (self.mode + 1) % 2;
        }
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, NoteParams {
                    .freq = A4 * rel_freq,
                    .note_on = down,
                });
            }
        }
    }
};
