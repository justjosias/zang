const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/c.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_curve
    c\\
    c\\Trigger a weird sound effect with the keyboard. The
    c\\sound is defined using a curve, and scales with the
    c\\frequency of the key you press.
;

const carrier_curve = [_]zang.CurveNode {
    zang.CurveNode { .t = 0.0, .value = 440.0 },
    zang.CurveNode { .t = 0.5, .value = 880.0 },
    zang.CurveNode { .t = 1.0, .value = 110.0 },
    zang.CurveNode { .t = 1.5, .value = 660.0 },
    zang.CurveNode { .t = 2.0, .value = 330.0 },
    zang.CurveNode { .t = 3.9, .value = 20.0 },
};

const modulator_curve = [_]zang.CurveNode {
    zang.CurveNode { .t = 0.0, .value = 110.0 },
    zang.CurveNode { .t = 1.5, .value = 55.0 },
    zang.CurveNode { .t = 3.0, .value = 220.0 },
};

const CurvePlayer = struct {
    pub const num_outputs = 1;
    pub const num_temps = 2;
    pub const Params = struct {
        sample_rate: f32,
        rel_freq: f32,
    };

    carrier_curve: zang.Curve,
    carrier: zang.SineOsc,
    modulator_curve: zang.Curve,
    modulator: zang.SineOsc,

    fn init() CurvePlayer {
        return CurvePlayer {
            .carrier_curve = zang.Curve.init(),
            .carrier = zang.SineOsc.init(),
            .modulator_curve = zang.Curve.init(),
            .modulator = zang.SineOsc.init(),
        };
    }

    fn paint(self: *CurvePlayer, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, note_id_changed: bool, params: Params) void {
        const freq_mul = params.rel_freq;

        zang.zero(span, temps[0]);
        self.modulator_curve.paint(span, [1][]f32{temps[0]}, [0][]f32{}, note_id_changed, zang.Curve.Params {
            .sample_rate = params.sample_rate,
            .function = .SmoothStep,
            .curve = modulator_curve,
            .freq_mul = freq_mul,
        });
        zang.zero(span, temps[1]);
        self.modulator.paint(span, [1][]f32{temps[1]}, [0][]f32{}, zang.SineOsc.Params {
            .sample_rate = params.sample_rate,
            .freq = zang.buffer(temps[0]),
            .phase = zang.constant(0.0),
        });
        zang.zero(span, temps[0]);
        self.carrier_curve.paint(span, [1][]f32{temps[0]}, [0][]f32{}, note_id_changed, zang.Curve.Params {
            .sample_rate = params.sample_rate,
            .function = .SmoothStep,
            .curve = carrier_curve,
            .freq_mul = freq_mul,
        });
        self.carrier.paint(span, outputs, [0][]f32{}, zang.SineOsc.Params {
            .sample_rate = params.sample_rate,
            .freq = zang.buffer(temps[0]),
            .phase = zang.buffer(temps[1]),
        });
    }
};

pub const MainModule = struct {
    pub const num_outputs = 1;
    pub const num_temps = 2;

    iq: zang.Notes(CurvePlayer.Params).ImpulseQueue,
    idgen: zang.IdGenerator,
    player: CurvePlayer,
    trigger: zang.Trigger(CurvePlayer.Params),

    pub fn init() MainModule {
        return MainModule {
            .iq = zang.Notes(CurvePlayer.Params).ImpulseQueue.init(),
            .idgen = zang.IdGenerator.init(),
            .player = CurvePlayer.init(),
            .trigger = zang.Trigger(CurvePlayer.Params).init(),
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        var ctr = self.trigger.counter(span, self.iq.consume());
        while (self.trigger.next(&ctr)) |result| {
            self.player.paint(result.span, outputs, temps, result.note_id_changed, result.params);
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (down) {
            if (common.getKeyRelFreq(key)) |rel_freq| {
                self.iq.push(impulse_frame, self.idgen.nextId(), CurvePlayer.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .rel_freq = rel_freq,
                });
            }
        }
    }
};
