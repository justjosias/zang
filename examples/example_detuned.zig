const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/c.zig");
const StereoEchoes = @import("modules.zig").StereoEchoes(15000);

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_detuned
    c\\
    c\\Play an instrument with the keyboard. There is a
    c\\random warble added to the note frequencies, which was
    c\\created using white noise and a low-pass filter.
    c\\
    c\\Press spacebar to cycle through a few modes:
    c\\
    c\\  1. wide warble, no echo
    c\\  2. narrow warble, no echo
    c\\  3. wide warble, echo
    c\\  4. narrow warble, echo (here the warble does a good
    c\\     job of avoiding constructive interference from
    c\\     the echo)
;

const a4 = 440.0;

pub const Instrument = struct {
    pub const num_outputs = 1;
    pub const num_temps = 3;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        freq_warble: []const f32,
        note_on: bool,
    };

    dc: zang.DC,
    osc: zang.TriSawOsc,
    env: zang.Envelope,
    main_filter: zang.Filter,

    pub fn init() Instrument {
        return Instrument {
            .dc = zang.DC.init(),
            .osc = zang.TriSawOsc.init(),
            .env = zang.Envelope.init(),
            .main_filter = zang.Filter.init(),
        };
    }

    pub fn paint(self: *Instrument, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, note_id_changed: bool, params: Params) void {
        var i: usize = span.start; while (i < span.end) : (i += 1) {
            temps[0][i] = params.freq * std.math.pow(f32, 2.0, params.freq_warble[i]);
        }
        // paint with oscillator into temps[1]
        zang.zero(span, temps[1]);
        self.osc.paint(span, [1][]f32{temps[1]}, [0][]f32{}, zang.TriSawOsc.Params {
            .sample_rate = params.sample_rate,
            .freq = zang.buffer(temps[0]),
            .color = 0.0,
        });
        // slight volume reduction
        zang.multiplyWithScalar(span, temps[1], 0.75);
        // combine with envelope
        zang.zero(span, temps[0]);
        self.env.paint(span, [1][]f32{temps[0]}, [0][]f32{}, note_id_changed, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack = zang.Painter.Curve { .Cubed = 0.025 },
            .decay = zang.Painter.Curve { .Cubed = 0.1 },
            .release = zang.Painter.Curve { .Cubed = 1.0 },
            .sustain_volume = 0.5,
            .note_on = params.note_on,
        });
        zang.zero(span, temps[2]);
        zang.multiply(span, temps[2], temps[1], temps[0]);
        // add main filter
        self.main_filter.paint(span, [1][]f32{outputs[0]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[2],
            .filter_type = .LowPass,
            .cutoff = zang.constant(zang.cutoffFromFrequency(880.0, params.sample_rate)),
            // .cutoff = zang.constant(zang.cutoffFromFrequency(params.freq + 400.0, params.sample_rate)),
            .resonance = 0.8,
        });
    }
};

pub const OuterInstrument = struct {
    pub const num_outputs = 1;
    pub const num_temps = 4;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
        mode: u32,
    };

    noise: zang.Noise,
    noise_filter: zang.Filter,
    inner: Instrument,

    pub fn init() OuterInstrument {
        return OuterInstrument {
            .noise = zang.Noise.init(0),
            .noise_filter = zang.Filter.init(),
            .inner = Instrument.init(),
        };
    }

    pub fn paint(self: *OuterInstrument, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, note_id_changed: bool, params: Params) void {
        // temps[0] = filtered noise
        // note: filter frequency is set to 4hz. i wanted to go slower but
        // unfortunately at below 4, the filter degrades and the output
        // frequency slowly sinks to zero
        // (the number is relative to sample rate, so at 96khz it should be at
        // least 8hz)
        zang.zero(span, temps[1]);
        self.noise.paint(span, [1][]f32{temps[1]}, [0][]f32{}, zang.Noise.Params {});
        zang.zero(span, temps[0]);
        self.noise_filter.paint(span, [1][]f32{temps[0]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[1],
            .filter_type = .LowPass,
            .cutoff = zang.constant(zang.cutoffFromFrequency(4.0, params.sample_rate)),
            .resonance = 0.0,
        });

        if ((params.mode & 1) == 0) {
            zang.multiplyWithScalar(span, temps[0], 4.0);
        }

        self.inner.paint(span, outputs, [3][]f32{temps[1], temps[2], temps[3]}, note_id_changed, Instrument.Params {
            .sample_rate = params.sample_rate,
            .freq = params.freq,
            .freq_warble = temps[0],
            .note_on = params.note_on,
        });
    }
};

pub const MainModule = struct {
    pub const num_outputs = 2;
    pub const num_temps = 5;

    key: ?i32,
    iq: zang.Notes(OuterInstrument.Params).ImpulseQueue,
    idgen: zang.IdGenerator,
    outer: OuterInstrument,
    trigger: zang.Trigger(OuterInstrument.Params),
    echoes: StereoEchoes,
    mode: u32,

    pub fn init() MainModule {
        return MainModule {
            .key = null,
            .iq = zang.Notes(OuterInstrument.Params).ImpulseQueue.init(),
            .idgen = zang.IdGenerator.init(),
            .outer = OuterInstrument.init(),
            .trigger = zang.Trigger(OuterInstrument.Params).init(),
            .echoes = StereoEchoes.init(),
            .mode = 0,
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        // FIXME - here's something missing in the API... what if i want to
        // pass some "global" params to paintFromImpulses? in other words,
        // saw that of the fields in OuterInstrument.Params, i only want to set
        // some of them in the impulse queue. others i just want to pass once,
        // here. for example i would pass the "mode" field.
        zang.zero(span, temps[0]);
        {
            var ctr = self.trigger.counter(span, self.iq.consume());
            while (self.trigger.next(&ctr)) |result| {
                self.outer.paint(result.span, [1][]f32{temps[0]}, [4][]f32{temps[1], temps[2], temps[3], temps[4]}, result.note_id_changed, result.params);
            }
        }

        if ((self.mode & 2) == 0) {
            // avoid the echo effect
            zang.addInto(span, outputs[0], temps[0]);
            zang.addInto(span, outputs[1], temps[0]);
            zang.zero(span, temps[0]);
        }

        self.echoes.paint(span, outputs, [4][]f32{temps[1], temps[2], temps[3], temps[4]}, StereoEchoes.Params {
            .input = temps[0],
            .feedback_volume = 0.6,
            .cutoff = 0.1,
        });
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (key == c.SDLK_SPACE and down) {
            self.mode = (self.mode + 1) & 3;
        }
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, self.idgen.nextId(), OuterInstrument.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .freq = a4 * rel_freq * 0.5,
                    .note_on = down,
                    // note: because i'm passing mode here, a change to mode
                    // take effect until you press a new key
                    .mode = self.mode,
                });
            }
        }
    }
};
