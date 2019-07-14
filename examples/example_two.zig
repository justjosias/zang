const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/c.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_two
    c\\
    c\\A single instrument triggered by two input sources.
    c\\Play the lower half of the keyboard to control the
    c\\note frequency. Press the number keys to change the
    c\\pulse oscillator's duty cycle. Both input sources
    c\\trigger the envelope.
;

const A4 = 880.0;

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;

    pub const Params0 = struct { freq: f32, note_on: bool };
    pub const Params1 = struct { colour: f32, note_on: bool };

    first: bool,

    osc: zang.PulseOsc,
    env: zang.Envelope,

    key0: ?i32,
    iq0: zang.Notes(Params0).ImpulseQueue,
    trig0: zang.Trigger(Params0),

    key1: ?i32,
    iq1: zang.Notes(Params1).ImpulseQueue,
    trig1: zang.Trigger(Params1),

    pub fn init() MainModule {
        return MainModule{
            .first = true,
            .osc = zang.PulseOsc.init(),
            .env = zang.Envelope.init(),
            .key0 = null,
            .iq0 = zang.Notes(Params0).ImpulseQueue.init(),
            .trig0 = zang.Trigger(Params0).init(),
            .key1 = null,
            .iq1 = zang.Notes(Params1).ImpulseQueue.init(),
            .trig1 = zang.Trigger(Params1).init(),
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        if (self.first) {
            self.first = false;
            self.iq0.push(0, Params0 { .freq = A4 * 0.5, .note_on = false });
            self.iq1.push(0, Params1 { .colour = 0.5, .note_on = false });
        }

        zang.zero(span, temps[0]);
        zang.zero(span, temps[1]);

        // note: this can be promoted to a library feature if i ever find a
        // non-dubious use for it.
        // as a library feature it would probably take the form of a new
        // iterator that consumes two source iterators (ctr0 and ctr1).
        // it could probably be made general to any number of source iterators.
        // what to do with note_on and note_id_changed is not obvious...

        var ctr0 = self.trig0.counter(span, self.iq0.consume());
        var ctr1 = self.trig1.counter(span, self.iq1.consume());

        var maybe_result0 = self.trig0.next(&ctr0);
        var maybe_result1 = self.trig1.next(&ctr1);

        var start = span.start;

        while (start < span.end) {
            // only paint if both impulse queues are active

            if (maybe_result0) |result0| {
            if (maybe_result1) |result1| {
                const inner_span = zang.Span {
                    .start = start,
                    .end = std.math.min(result0.span.end, result1.span.end),
                };
                self.osc.paint(
                    inner_span,
                    [1][]f32{temps[0]},
                    [0][]f32{},
                    zang.PulseOsc.Params {
                        .sample_rate = AUDIO_SAMPLE_RATE,
                        .freq = result0.params.freq,
                        .colour = result1.params.colour,
                    },
                );
                self.env.paint(
                    inner_span,
                    [1][]f32{temps[1]},
                    [0][]f32{},
                    (
                        // only reset the envelope when a button is depressed
                        // when no buttons were previous depressed
                        (result0.note_id_changed and result0.params.note_on and !result1.note_id_changed)
                        or
                        (result1.note_id_changed and result1.params.note_on and !result0.note_id_changed)
                    ),
                    zang.Envelope.Params {
                        .sample_rate = AUDIO_SAMPLE_RATE,
                        .attack_duration = 0.025,
                        .decay_duration = 0.1,
                        .sustain_volume = 0.5,
                        .release_duration = 1.0,
                        .note_on = result0.params.note_on or result1.params.note_on,
                    },
                );
                if (result0.span.end == inner_span.end) {
                    maybe_result0 = self.trig0.next(&ctr0);
                }
                if (result1.span.end == inner_span.end) {
                    maybe_result1 = self.trig1.next(&ctr1);
                }
                start = inner_span.end;
                continue;
            }}

            break;
        }

        zang.multiply(span, outputs[0], temps[0], temps[1]);
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (common.getKeyRelFreqFromRow(0, key)) |rel_freq| {
            if (down or (if (self.key0) |nh| nh == key else false)) {
                self.key0 = if (down) key else null;
                self.iq0.push(impulse_frame, Params0 {
                    .freq = A4 * rel_freq,
                    .note_on = down,
                });
            }
        }

        if (key >= c.SDLK_1 and key <= c.SDLK_9) {
            const f = @intToFloat(f32, key - c.SDLK_1) / @intToFloat(f32, c.SDLK_9 - c.SDLK_1);
            if (down or (if (self.key1) |nh| nh == key else false)) {
                self.key1 = if (down) key else null;
                self.iq1.push(impulse_frame, Params1 {
                    .colour = 0.5 + std.math.sqrt(f) * 0.49,
                    .note_on = down,
                });
            }
        }
    }
};
