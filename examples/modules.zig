const zang = @import("zang");
const note_frequencies = @import("zang-12tet");

pub const PhaseModOscillator = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 3;
    pub const Params = struct {
        freq: f32,
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

    pub fn reset(self: *PhaseModOscillator) void {
        self.carrier.reset();
        self.modulator.reset();
    }

    pub fn paint(self: *PhaseModOscillator, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const out = outputs[0];

        zang.set(temps[0], params.freq);
        switch (params.ratio) {
            .Constant => |ratio| zang.set(temps[1], params.freq * ratio),
            .Buffer => |ratio| zang.multiplyScalar(temps[1], ratio, params.freq),
        }
        zang.zero(temps[2]);
        self.modulator.paint(sample_rate, [1][]f32{temps[2]}, [0][]f32{}, zang.Oscillator.Params {
            .waveform = .Sine,
            .freq = zang.buffer(temps[1]),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });
        zang.zero(temps[1]);
        switch (params.multiplier) {
            .Constant => |multiplier| zang.multiplyScalar(temps[1], temps[2], multiplier),
            .Buffer => |multiplier| zang.multiply(temps[1], temps[2], multiplier),
        }
        self.carrier.paint(sample_rate, [1][]f32{out}, [0][]f32{}, zang.Oscillator.Params {
            .waveform = .Sine,
            .freq = zang.buffer(temps[0]),
            .phase = zang.buffer(temps[1]),
            .colour = 0.5,
        });
    }
};

// PhaseModOscillator packaged with an envelope
pub const PMOscInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 4;
    pub const Params = struct { freq: f32, note_on: bool };

    osc: PhaseModOscillator,
    env: zang.Envelope,

    pub fn init(release_duration: f32) PMOscInstrument {
        return PMOscInstrument {
            .osc = PhaseModOscillator.init(),
            .env = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = release_duration,
            }),
        };
    }

    pub fn reset(self: *PMOscInstrument) void {
        self.osc.reset();
        self.env.reset();
    }

    pub fn paint(self: *PMOscInstrument, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        zang.zero(temps[0]);
        self.osc.paint(sample_rate, [1][]f32{temps[0]}, [3][]f32{temps[1], temps[2], temps[3]}, PhaseModOscillator.Params {
            .freq = params.freq,
            .ratio = zang.constant(1.0),
            .multiplier = zang.constant(1.5),
        });
        zang.zero(temps[1]);
        self.env.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Envelope.Params {
            .note_on = params.note_on,
        });
        zang.multiply(outputs[0], temps[0], temps[1]);
    }
};

pub const FilteredSawtoothInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 3;
    pub const Params = struct { freq: f32, note_on: bool };

    osc: zang.Oscillator,
    env: zang.Envelope,
    flt: zang.Filter,

    pub fn init() FilteredSawtoothInstrument {
        return FilteredSawtoothInstrument {
            .osc = zang.Oscillator.init(),
            .env = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 1.0,
            }),
            .flt = zang.Filter.init(),
        };
    }

    pub fn reset(self: *FilteredSawtoothInstrument) void {
        self.osc.reset();
        self.env.reset();
        self.flt.reset();
    }

    pub fn paint(self: *FilteredSawtoothInstrument, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        zang.zero(temps[0]);
        self.osc.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Oscillator.Params {
            .waveform = .Sawtooth,
            .freq = zang.constant(params.freq),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });
        zang.multiplyWithScalar(temps[0], 1.5); // boost sawtooth volume
        zang.zero(temps[1]);
        self.env.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Envelope.Params {
            .note_on = params.note_on,
        });
        zang.zero(temps[2]);
        zang.multiply(temps[2], temps[0], temps[1]);
        self.flt.paint(sample_rate, [1][]f32{outputs[0]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[2],
            .filterType = .LowPass,
            .cutoff = zang.constant(zang.cutoffFromFrequency(440.0 * note_frequencies.C5, sample_rate)),
            .resonance = 0.7,
        });
    }
};

pub const NiceInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct { freq: f32, note_on: bool };

    osc: zang.PulseOsc,
    flt: zang.Filter,
    env: zang.Envelope,

    pub fn init() NiceInstrument {
        return NiceInstrument {
            .osc = zang.PulseOsc.init(),
            .flt = zang.Filter.init(),
            .env = zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.01,
                .decay_duration = 0.1,
                .sustain_volume = 0.8,
                .release_duration = 0.5,
            }),
        };
    }

    pub fn reset(self: *NiceInstrument) void {
        self.osc.reset();
        self.flt.reset();
        self.env.reset();
    }

    pub fn paint(self: *NiceInstrument, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        zang.zero(temps[0]);
        self.osc.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.PulseOsc.Params {
            .freq = params.freq,
            .colour = 0.3,
        });
        zang.multiplyWithScalar(temps[0], 0.5);
        zang.zero(temps[1]);
        self.flt.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Filter.Params {
            .input = temps[0],
            .filterType = .LowPass,
            .cutoff = zang.constant(zang.cutoffFromFrequency(params.freq * 8.0, sample_rate)),
            .resonance = 0.7,
        });
        zang.zero(temps[0]);
        self.env.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.Envelope.Params {
            .note_on = params.note_on,
        });
        zang.multiply(outputs[0], temps[0], temps[1]);
    }
};

pub const HardSquareInstrument = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct { freq: f32, note_on: bool };

    osc: zang.PulseOsc,
    gate: zang.Gate,

    pub fn init() HardSquareInstrument {
        return HardSquareInstrument {
            .osc = zang.PulseOsc.init(),
            .gate = zang.Gate.init(),
        };
    }

    pub fn reset(self: *HardSquareInstrument) void {
        self.osc.reset();
        self.gate.reset();
    }

    pub fn paint(self: *HardSquareInstrument, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        zang.zero(temps[0]);
        self.osc.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, zang.PulseOsc.Params {
            .freq = params.freq,
            .colour = 0.5,
        });
        zang.zero(temps[1]);
        self.gate.paint(sample_rate, [1][]f32{temps[1]}, [0][]f32{}, zang.Gate.Params {
            .note_on = params.note_on,
        });
        zang.multiply(outputs[0], temps[0], temps[1]);
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

        pub fn reset(self: *@This()) void {}

        pub fn paint(self: *@This(), sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
            var output = outputs[0];
            var input = params.input;

            while (true) {
                const samples_read = self.delay.readDelayBuffer(output);

                self.delay.writeDelayBuffer(input[0..samples_read]);

                if (samples_read == output.len) {
                    break;
                } else {
                    output = output[samples_read..];
                    input = input[samples_read..];
                }
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

        pub fn reset(self: *@This()) void {}

        pub fn paint(self: *@This(), sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
            var output = outputs[0];
            var input = params.input;
            var temp0 = temps[0];
            var temp1 = temps[1];

            while (true) {
                // get delay buffer (this is the feedback)
                zang.zero(temp0);
                const samples_read = self.delay.readDelayBuffer(temp0);

                // reduce its volume
                zang.multiplyWithScalar(temp0[0..samples_read], params.feedback_volume);

                // add input
                zang.addInto(temp0[0..samples_read], input[0..samples_read]);

                // filter it
                zang.zero(temp1[0..samples_read]);
                self.filter.paint(sample_rate, [1][]f32{temp1[0..samples_read]}, [0][]f32{}, zang.Filter.Params {
                    .input = temp0[0..samples_read],
                    .filterType = .LowPass,
                    .cutoff = zang.constant(params.cutoff),
                    .resonance = 0.0,
                });

                // output it
                zang.addInto(output[0..samples_read], temp1[0..samples_read]);

                // also send what we have to the delay module (which doesn't output anything)
                self.delay.writeDelayBuffer(temp1[0..samples_read]);

                if (samples_read == output.len) {
                    break;
                } else {
                    output = output[samples_read..];
                    input = input[samples_read..];
                    temp0 = temp0[samples_read..];
                    temp1 = temp1[samples_read..];
                }
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

    pub fn reset(self: *StereoEchoes) void {}

    pub fn paint(self: *StereoEchoes, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        // output dry signal to center channel
        zang.addInto(outputs[0], params.input);
        zang.addInto(outputs[1], params.input);

        // initial half delay before first echo on the left channel
        zang.zero(temps[0]);
        self.delay0.paint(sample_rate, [1][]f32{temps[0]}, [0][]f32{}, SimpleDelay(HALF_DELAY).Params {
            .input = params.input,
        });
        // filtered echoes to the left
        zang.zero(temps[1]);
        self.echoes.paint(sample_rate, [1][]f32{temps[1]}, [2][]f32{temps[2], temps[3]}, FilteredEchoes(MAIN_DELAY).Params {
            .input = temps[0],
            .feedback_volume = params.feedback_volume,
            .cutoff = params.cutoff,
        });
        // use another delay to mirror the left echoes to the right side
        zang.addInto(outputs[0], temps[1]);
        self.delay1.paint(sample_rate, [1][]f32{outputs[1]}, [0][]f32{}, SimpleDelay(HALF_DELAY).Params {
            .input = temps[1],
        });
    }
};
