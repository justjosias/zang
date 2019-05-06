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
