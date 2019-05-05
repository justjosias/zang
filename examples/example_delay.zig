const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");
const Instrument = @import("modules.zig").HardSquareInstrument;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

const A4 = 440.0;

const Delay = zang.Delay(15000);

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 1 + Instrument.NumTemps;

    iq: zang.Notes(Instrument.Params).ImpulseQueue,
    key: ?i32,
    instr: zang.Triggerable(Instrument),
    delay: Delay,

    pub fn init() MainModule {
        return MainModule{
            .iq = zang.Notes(Instrument.Params).ImpulseQueue.init(),
            .key = null,
            .instr = zang.initTriggerable(Instrument.init()),
            .delay = Delay.init(),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        zang.zero(temps[0]);
        var instr_temps: [Instrument.NumTemps][]f32 = undefined;
        var i: usize = 0; while (i < Instrument.NumTemps) : (i += 1) {
            instr_temps[i] = temps[1 + i];
        }
        self.instr.paintFromImpulses(sample_rate, [1][]f32{temps[0]}, instr_temps, self.iq.consume());
        zang.addInto(outputs[0], temps[0]);
        zang.multiplyWithScalar(temps[0], 0.5);
        self.delay.paint(sample_rate, outputs, [0][]f32{}, Delay.Params {
            .input = temps[0],
            .feedback_level = 0.6,
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
