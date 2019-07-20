const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet");

pub const PhaseModOscillator = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 3;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        relative: bool,
        // ratio: the carrier oscillator will use whatever frequency you give the
        // PhaseModOscillator. the modulator oscillator will multiply the frequency
        // by this ratio. for example, a ratio of 0.5 means that the modulator
        // oscillator will always play at half the frequency of the carrier
        // oscillator
        ratio: zang.ConstantOrBuffer,
        // multiplier: the modulator oscillator's output is multiplied by this
        // before it is fed in to the phase input of the carrier oscillator.
        multiplier: zang.ConstantOrBuffer,
    };

    carrier: zang.Oscillator,
    modulator: zang.Oscillator,

    pub fn init() PhaseModOscillator {
        return PhaseModOscillator {
            .carrier = zang.Oscillator.init(),
            .modulator = zang.Oscillator.init(),
        };
    }

    pub fn paint(self: *PhaseModOscillator, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        zang.set(span, temps[0], params.freq);
        switch (params.ratio) {
            .Constant => |ratio| {
                if (params.relative) {
                    zang.set(span, temps[1], params.freq * ratio);
                } else {
                    zang.set(span, temps[1], ratio);
                }
            },
            .Buffer => |ratio| {
                if (params.relative) {
                    zang.multiplyScalar(span, temps[1], ratio, params.freq);
                } else {
                    zang.copy(span, temps[1], ratio);
                }
            },
        }
        zang.zero(span, temps[2]);
        self.modulator.paint(span, [1][]f32{temps[2]}, [0][]f32{}, zang.Oscillator.Params {
            .sample_rate = params.sample_rate,
            .waveform = .Sine,
            .freq = zang.buffer(temps[1]),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });
        zang.zero(span, temps[1]);
        switch (params.multiplier) {
            .Constant => |multiplier| zang.multiplyScalar(span, temps[1], temps[2], multiplier),
            .Buffer => |multiplier| zang.multiply(span, temps[1], temps[2], multiplier),
        }
        zang.zero(span, temps[2]);
        self.carrier.paint(span, [1][]f32{temps[2]}, [0][]f32{}, zang.Oscillator.Params {
            .sample_rate = params.sample_rate,
            .waveform = .Sine,
            .freq = zang.buffer(temps[0]),
            .phase = zang.buffer(temps[1]),
            .colour = 0.5,
        });
        zang.addInto(span, outputs[0], temps[2]);
    }
};

// PhaseModOscillator packaged with an envelope
pub const PMOscInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 4;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    release_duration: f32,
    osc: PhaseModOscillator,
    env: zang.Envelope,

    pub fn init(release_duration: f32) PMOscInstrument {
        return PMOscInstrument {
            .release_duration = release_duration,
            .osc = PhaseModOscillator.init(),
            .env = zang.Envelope.init(),
        };
    }

    pub fn paint(self: *PMOscInstrument, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, note_id_changed: bool, params: Params) void {
        zang.zero(span, temps[0]);
        self.osc.paint(span, [1][]f32{temps[0]}, [3][]f32{temps[1], temps[2], temps[3]}, PhaseModOscillator.Params {
            .sample_rate = params.sample_rate,
            .freq = params.freq,
            .relative = true,
            .ratio = zang.constant(1.0),
            .multiplier = zang.constant(1.0),
        });
        zang.zero(span, temps[1]);
        self.env.paint(span, [1][]f32{temps[1]}, [0][]f32{}, note_id_changed, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack_duration = 0.025,
            .decay_duration = 0.1,
            .sustain_volume = 0.5,
            .release_duration = self.release_duration,
            .note_on = params.note_on,
        });
        zang.multiply(span, outputs[0], temps[0], temps[1]);
    }
};

pub const FilteredSawtoothInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 3;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    osc: zang.Oscillator,
    env: zang.Envelope,
    flt: zang.Filter,

    pub fn init() FilteredSawtoothInstrument {
        return FilteredSawtoothInstrument {
            .osc = zang.Oscillator.init(),
            .env = zang.Envelope.init(),
            .flt = zang.Filter.init(),
        };
    }

    pub fn paint(self: *FilteredSawtoothInstrument, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, note_id_changed: bool, params: Params) void {
        zang.zero(span, temps[0]);
        self.osc.paint(span, [1][]f32{temps[0]}, [0][]f32{}, zang.Oscillator.Params {
            .sample_rate = params.sample_rate,
            .waveform = .Sawtooth,
            .freq = zang.constant(params.freq),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });
        zang.multiplyWithScalar(span, temps[0], 1.5); // boost sawtooth volume
        zang.zero(span, temps[1]);
        self.env.paint(span, [1][]f32{temps[1]}, [0][]f32{}, note_id_changed, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack_duration = 0.025,
            .decay_duration = 0.1,
            .sustain_volume = 0.5,
            .release_duration = 1.0,
            .note_on = params.note_on,
        });
        zang.zero(span, temps[2]);
        zang.multiply(span, temps[2], temps[0], temps[1]);
        self.flt.paint(span, [1][]f32{outputs[0]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[2],
            .filterType = .LowPass,
            .cutoff = zang.constant(zang.cutoffFromFrequency(440.0 * note_frequencies.C5, params.sample_rate)),
            .resonance = 0.7,
        });
    }
};

pub const NiceInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    osc: zang.PulseOsc,
    flt: zang.Filter,
    env: zang.Envelope,

    pub fn init() NiceInstrument {
        return NiceInstrument {
            .osc = zang.PulseOsc.init(),
            .flt = zang.Filter.init(),
            .env = zang.Envelope.init(),
        };
    }

    pub fn paint(self: *NiceInstrument, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, note_id_changed: bool, params: Params) void {
        zang.zero(span, temps[0]);
        self.osc.paint(span, [1][]f32{temps[0]}, [0][]f32{}, zang.PulseOsc.Params {
            .sample_rate = params.sample_rate,
            .freq = params.freq,
            .colour = 0.3,
        });
        zang.multiplyWithScalar(span, temps[0], 0.5);
        zang.zero(span, temps[1]);
        self.flt.paint(span, [1][]f32{temps[1]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[0],
            .filterType = .LowPass,
            .cutoff = zang.constant(zang.cutoffFromFrequency(params.freq * 8.0, params.sample_rate)),
            .resonance = 0.7,
        });
        zang.zero(span, temps[0]);
        self.env.paint(span, [1][]f32{temps[0]}, [0][]f32{}, note_id_changed, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack_duration = 0.01,
            .decay_duration = 0.1,
            .sustain_volume = 0.8,
            .release_duration = 0.5,
            .note_on = params.note_on,
        });
        zang.multiply(span, outputs[0], temps[0], temps[1]);
    }
};

pub const HardSquareInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    osc: zang.PulseOsc,
    gate: zang.Gate,

    pub fn init() HardSquareInstrument {
        return HardSquareInstrument {
            .osc = zang.PulseOsc.init(),
            .gate = zang.Gate.init(),
        };
    }

    pub fn paint(self: *HardSquareInstrument, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, note_id_changed: bool, params: Params) void {
        zang.zero(span, temps[0]);
        self.osc.paint(span, [1][]f32{temps[0]}, [0][]f32{}, zang.PulseOsc.Params {
            .sample_rate = params.sample_rate,
            .freq = params.freq,
            .colour = 0.5,
        });
        zang.zero(span, temps[1]);
        self.gate.paint(span, [1][]f32{temps[1]}, [0][]f32{}, zang.Gate.Params {
            .note_on = params.note_on,
        });
        zang.multiply(span, outputs[0], temps[0], temps[1]);
    }
};

pub const SquareWithEnvelope = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct {
        sample_rate: f32,
        freq: f32,
        note_on: bool,
    };

    weird: bool,
    osc: zang.PulseOsc,
    env: zang.Envelope,

    pub fn init(weird: bool) SquareWithEnvelope {
        return SquareWithEnvelope {
            .weird = weird,
            .osc = zang.PulseOsc.init(),
            .env = zang.Envelope.init(),
        };
    }

    pub fn paint(self: *SquareWithEnvelope, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, note_id_changed: bool, params: Params) void {
        zang.zero(span, temps[0]);
        self.osc.paint(span, [1][]f32{temps[0]}, [0][]f32{}, zang.PulseOsc.Params {
            .sample_rate = params.sample_rate,
            .freq = params.freq,
            .colour = if (self.weird) f32(0.3) else f32(0.5),
        });
        zang.zero(span, temps[1]);
        self.env.paint(span, [1][]f32{temps[1]}, [0][]f32{}, note_id_changed, zang.Envelope.Params {
            .sample_rate = params.sample_rate,
            .attack_duration = 0.01,
            .decay_duration = 0.1,
            .sustain_volume = 0.5,
            .release_duration = 0.5,
            .note_on = params.note_on,
        });
        zang.multiply(span, outputs[0], temps[0], temps[1]);
    }
};

// this is a module that simply delays the input signal. there's no dry output
// and no feedback (echoes)
pub fn SimpleDelay(comptime DELAY_SAMPLES: usize) type {
    return struct {
        pub const NumOutputs = 1;
        pub const NumTemps = 0;
        pub const Params = struct {
            input: []const f32,
        };

        delay: zang.Delay(DELAY_SAMPLES),

        pub fn init() @This() {
            return @This() {
                .delay = zang.Delay(DELAY_SAMPLES).init(),
            };
        }

        pub fn reset(self: *@This()) void {
            self.delay.reset();
        }

        pub fn paint(self: *@This(), span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
            var start = span.start;
            const end = span.end;

            while (start < end) {
                const samples_read = self.delay.readDelayBuffer(outputs[0][start .. end]);

                self.delay.writeDelayBuffer(params.input[start .. start + samples_read]);

                start += samples_read;
            }
        }
    };
}

// this is a bit unusual, it filters the input and outputs it immediately. it's
// meant to be used after SimpleDelay (which provides the initial delay)
pub fn FilteredEchoes(comptime DELAY_SAMPLES: usize) type {
    return struct {
        pub const NumOutputs = 1;
        pub const NumTemps = 2;
        pub const Params = struct {
            input: []const f32,
            feedback_volume: f32,
            cutoff: f32,
        };

        delay: zang.Delay(DELAY_SAMPLES),
        filter: zang.Filter,

        pub fn init() @This() {
            return @This() {
                .delay = zang.Delay(DELAY_SAMPLES).init(),
                .filter = zang.Filter.init(),
            };
        }

        pub fn reset(self: *@This()) void {
            self.delay.reset();
        }

        pub fn paint(self: *@This(), span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
            const output = outputs[0];
            const input = params.input;
            const temp0 = temps[0];
            const temp1 = temps[1];

            var start = span.start;
            const end = span.end;

            while (start < end) {
                // get delay buffer (this is the feedback)
                zang.zero(zang.Span { .start = start, .end = end }, temp0);
                const samples_read = self.delay.readDelayBuffer(temp0[start..end]);

                const span1 = zang.Span { .start = start, .end = start + samples_read };

                // reduce its volume
                zang.multiplyWithScalar(span1, temp0, params.feedback_volume);

                // add input
                zang.addInto(span1, temp0, input);

                // filter it
                zang.zero(span1, temp1);
                self.filter.paint(span1, [1][]f32{temp1}, [0][]f32{}, zang.Filter.Params {
                    .input = temp0,
                    .filterType = .LowPass,
                    .cutoff = zang.constant(params.cutoff),
                    .resonance = 0.0,
                });

                // output it
                zang.addInto(span1, output, temp1);

                // also send what we have to the delay module (which doesn't output anything)
                self.delay.writeDelayBuffer(temp1[span1.start..span1.end]);

                start += samples_read;
            }
        }
    };
}

const MAIN_DELAY = 15000;
const HALF_DELAY = MAIN_DELAY / 2;

pub const StereoEchoes = struct {
    pub const NumOutputs = 2;
    pub const NumTemps = 4;
    pub const Params = struct {
        input: []const f32,
        feedback_volume: f32,
        cutoff: f32,
    };

    delay0: SimpleDelay(HALF_DELAY),
    delay1: SimpleDelay(HALF_DELAY),
    echoes: FilteredEchoes(MAIN_DELAY),

    pub fn init() StereoEchoes {
        return StereoEchoes {
            .delay0 = SimpleDelay(HALF_DELAY).init(),
            .delay1 = SimpleDelay(HALF_DELAY).init(),
            .echoes = FilteredEchoes(MAIN_DELAY).init(),
        };
    }

    pub fn reset(self: *StereoEchoes) void {
        self.delay0.reset();
        self.delay1.reset();
        self.echoes.reset();
    }

    pub fn paint(self: *StereoEchoes, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        // output dry signal to center channel
        zang.addInto(span, outputs[0], params.input);
        zang.addInto(span, outputs[1], params.input);

        // initial half delay before first echo on the left channel
        zang.zero(span, temps[0]);
        self.delay0.paint(span, [1][]f32{temps[0]}, [0][]f32{}, SimpleDelay(HALF_DELAY).Params {
            .input = params.input,
        });
        // filtered echoes to the left
        zang.zero(span, temps[1]);
        self.echoes.paint(span, [1][]f32{temps[1]}, [2][]f32{temps[2], temps[3]}, FilteredEchoes(MAIN_DELAY).Params {
            .input = temps[0],
            .feedback_volume = params.feedback_volume,
            .cutoff = params.cutoff,
        });
        // use another delay to mirror the left echoes to the right side
        zang.addInto(span, outputs[0], temps[1]);
        self.delay1.paint(span, [1][]f32{outputs[1]}, [0][]f32{}, SimpleDelay(HALF_DELAY).Params {
            .input = temps[1],
        });
    }
};
