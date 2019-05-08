const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");
const Instrument = @import("modules.zig").HardSquareInstrument;
const StereoEchoes = @import("modules.zig").StereoEchoes;

pub const DESCRIPTION =
    c\\example_delay
    c\\
    c\\Play a square-wave instrument with the
    c\\keyboard.
    c\\There is a stereo echo effect.
;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

const A4 = 440.0;

pub const MainModule = struct {
    pub const NumOutputs = 2;
    pub const NumTemps = 3 + Instrument.NumTemps;

    iq: zang.Notes(Instrument.Params).ImpulseQueue,
    key: ?i32,
    instr: zang.Triggerable(Instrument),
    echoes: StereoEchoes,

    pub fn init() MainModule {
        return MainModule {
            .iq = zang.Notes(Instrument.Params).ImpulseQueue.init(),
            .key = null,
            .instr = zang.initTriggerable(Instrument.init()),
            .echoes = StereoEchoes.init(),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        zang.zero(temps[0]);
        var instr_temps: [Instrument.NumTemps][]f32 = undefined;
        var i: usize = 0; while (i < Instrument.NumTemps) : (i += 1) {
            instr_temps[i] = temps[3 + i];
        }
        self.instr.paintFromImpulses(sample_rate, [1][]f32{temps[0]}, instr_temps, self.iq.consume());

        self.echoes.paint(sample_rate, outputs, [4][]f32{temps[1], temps[2], temps[3], temps[4]}, StereoEchoes.Params {
            .input = temps[0],
            .feedback_volume = 0.6,
            .cutoff = 0.1,
        });
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, Instrument.Params {
                    .freq = A4 * rel_freq,
                    .note_on = down,
                });
            }
        }
    }
};
