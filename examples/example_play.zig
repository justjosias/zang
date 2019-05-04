// in this example you can play a simple monophonic synth with the keyboard

const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");
const PMOscInstrument = @import("modules.zig").PMOscInstrument;
const FilteredSawtoothInstrument = @import("modules.zig").FilteredSawtoothInstrument;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

const A4 = 440.0;

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 4;

    iq0: zang.Notes(PMOscInstrument.Params).ImpulseQueue,
    key0: ?i32,
    instr0: zang.Triggerable(PMOscInstrument),
    iq1: zang.Notes(FilteredSawtoothInstrument.Params).ImpulseQueue,
    instr1: zang.Triggerable(FilteredSawtoothInstrument),

    pub fn init() MainModule {
        return MainModule{
            .iq0 = zang.Notes(PMOscInstrument.Params).ImpulseQueue.init(),
            .key0 = null,
            .instr0 = zang.initTriggerable(PMOscInstrument.init(1.0)),
            .iq1 = zang.Notes(FilteredSawtoothInstrument.Params).ImpulseQueue.init(),
            .instr1 = zang.initTriggerable(FilteredSawtoothInstrument.init()),
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        self.instr0.paintFromImpulses(sample_rate, outputs, temps, self.iq0.consume());
        self.instr1.paintFromImpulses(sample_rate, outputs, temps, self.iq1.consume());
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (key == c.SDLK_SPACE) {
            self.iq1.push(impulse_frame, FilteredSawtoothInstrument.Params {
                .freq = A4 * note_frequencies.C4 / 4.0,
                .note_on = down,
            });
        } else if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key0) |nh| nh == key else false)) {
                self.key0 = if (down) key else null;
                self.iq0.push(impulse_frame, PMOscInstrument.Params {
                    .freq = A4 * rel_freq,
                    .note_on = down,
                });
            }
        }
    }
};
