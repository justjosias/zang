const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/c.zig");
const Instrument = @import("scriptgen.zig").Instrument;

pub const AUDIO_FORMAT: zang.AudioFormat = .signed16_lsb;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    \\example_script
    \\
    \\Play a scripted sound module with the keyboard.
;

const a4 = 440.0;

pub const MainModule = struct {
    pub const num_outputs = Instrument.num_outputs;
    pub const num_temps = Instrument.num_temps;

    key: ?i32,
    iq: zang.Notes(Instrument.Params).ImpulseQueue,
    idgen: zang.IdGenerator,
    instr: Instrument,
    trig: zang.Trigger(Instrument.Params),

    pub fn init() MainModule {
        return .{
            .key = null,
            .iq = zang.Notes(Instrument.Params).ImpulseQueue.init(),
            .idgen = zang.IdGenerator.init(),
            .instr = Instrument.init(),
            .trig = zang.Trigger(Instrument.Params).init(),
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        var ctr = self.trig.counter(span, self.iq.consume());
        while (self.trig.next(&ctr)) |result| {
            //self.instr.paint(result.span, outputs, temps, result.note_id_changed, result.params);
            self.instr.paint(result.span, outputs, temps, result.params);
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        var freq_buf: [AUDIO_BUFFER_SIZE]f32 = undefined;

        const rel_freq = common.getKeyRelFreq(key) orelse return;
        if (down or (if (self.key) |nh| nh == key else false)) {
            self.key = if (down) key else null;

            const freq = a4 * rel_freq;
            zang.set(zang.Span.init(0, AUDIO_BUFFER_SIZE), &freq_buf, freq);

            self.iq.push(impulse_frame, self.idgen.nextId(), .{
                .sample_rate = AUDIO_SAMPLE_RATE,
                .freq = &freq_buf,
                .color = 0.5,
                .note_on = down,
            });
        }
    }
};
