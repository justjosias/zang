const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/c.zig");
const Instrument = @import("modules.zig").HardSquareInstrument;
const StereoEchoes = @import("modules.zig").StereoEchoes(15000);

pub const DESCRIPTION =
    \\example_delay
    \\
    \\Play a square-wave instrument with the keyboard. There
    \\is a stereo echo effect.
    \\
    \\Press spacebar to reset the delay effect.
;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

const a4 = 440.0;

pub const MainModule = struct {
    pub const num_outputs = 2;
    pub const num_temps = 3 + Instrument.num_temps;

    key: ?i32,
    iq: zang.Notes(Instrument.Params).ImpulseQueue,
    idgen: zang.IdGenerator,
    instr: Instrument,
    trigger: zang.Trigger(Instrument.Params),
    echoes: StereoEchoes,

    pub fn init() MainModule {
        return MainModule {
            .key = null,
            .iq = zang.Notes(Instrument.Params).ImpulseQueue.init(),
            .idgen = zang.IdGenerator.init(),
            .instr = Instrument.init(),
            .trigger = zang.Trigger(Instrument.Params).init(),
            .echoes = StereoEchoes.init(),
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        zang.zero(span, temps[0]);
        var instr_temps: [Instrument.num_temps][]f32 = undefined;
        var i: usize = 0; while (i < Instrument.num_temps) : (i += 1) {
            instr_temps[i] = temps[3 + i];
        }
        var ctr = self.trigger.counter(span, self.iq.consume());
        while (self.trigger.next(&ctr)) |result| {
            self.instr.paint(result.span, [1][]f32{temps[0]}, instr_temps, result.note_id_changed, result.params);
        }

        self.echoes.paint(span, outputs, [4][]f32{temps[1], temps[2], temps[3], temps[4]}, StereoEchoes.Params {
            .input = temps[0],
            .feedback_volume = 0.6,
            .cutoff = 0.1,
        });
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (key == c.SDLK_SPACE) {
            self.echoes.reset();
        } else if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, self.idgen.nextId(), Instrument.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .freq = a4 * rel_freq,
                    .note_on = down,
                });
            }
        }
    }
};
