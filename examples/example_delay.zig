// in this example you can play the keyboard and there is a ping-pong stereo
// echo effect

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
const Delay2 = zang.Delay(7500);

pub const MainModule = struct {
    pub const NumOutputs = 2;
    pub const NumTemps = 2 + Instrument.NumTemps;

    iq: zang.Notes(Instrument.Params).ImpulseQueue,
    key: ?i32,
    instr: zang.Triggerable(Instrument),
    delay0: Delay,
    delay1: Delay,
    delay2: Delay2,

    pub fn init() MainModule {
        return MainModule{
            .iq = zang.Notes(Instrument.Params).ImpulseQueue.init(),
            .key = null,
            .instr = zang.initTriggerable(Instrument.init()),
            .delay0 = Delay.init(),
            .delay1 = Delay.init(),
            .delay2 = Delay2.init(),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        zang.zero(temps[0]);
        var instr_temps: [Instrument.NumTemps][]f32 = undefined;
        var i: usize = 0; while (i < Instrument.NumTemps) : (i += 1) {
            instr_temps[i] = temps[2 + i];
        }
        self.instr.paintFromImpulses(sample_rate, [1][]f32{temps[0]}, instr_temps, self.iq.consume());
        zang.addInto(outputs[0], temps[0]);
        zang.addInto(outputs[1], temps[0]);

        zang.multiplyWithScalar(temps[0], 0.6);

        zang.zero(temps[1]);
        self.delay2.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, Delay2.Params {
            .input = temps[0],
            .feedback_level = 0.0,
        });

        zang.addInto(outputs[1], temps[1]);

        self.delay0.paint(sample_rate, [1][]f32{outputs[0]}, [0][]f32{}, Delay.Params {
            .input = temps[0],
            .feedback_level = 0.6,
        });
        self.delay1.paint(sample_rate, [1][]f32{outputs[1]}, [0][]f32{}, Delay.Params {
            .input = temps[1],
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
