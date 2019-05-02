const std = @import("std");
const ConstantOrBuffer = @import("triggerable.zig").ConstantOrBuffer;

pub const Waveform = enum {
    Sine,
    Triangle,
    Square,
    Sawtooth,
};

pub fn tri(t: f32) f32 {
    const frac = t - std.math.floor(t);
    if (frac < 0.25) {
        return frac * 4.0;
    } else if (frac < 0.75) {
        return 1.0 - (frac - 0.25) * 4.0;
    } else {
        return (frac - 0.75) * 4.0 - 1.0;
    }
}

pub fn saw(t: f32) f32 {
    const frac = t - std.math.floor(t);
    return frac;
}

pub fn square(t: f32, colour: f32) f32 {
    const frac = t - std.math.floor(t);
    return if (frac < colour) f32(1.0) else f32(-1.0);
}

pub fn sin(t: f32) f32 {
    return std.math.sin(t * std.math.pi * 2.0);
}

fn oscFunc(waveform: Waveform) fn (t: f32) f32 {
    return switch (waveform) {
        .Sine => sin,
        .Triangle => tri,
        .Square => square,
        .Sawtooth => saw,
    };
}

fn osc(waveform: Waveform, t: f32) f32 {
    return oscFunc(waveform)(t);
}

pub const Oscillator = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 0;
    pub const Params = struct {
        waveform: Waveform,
        freq: ConstantOrBuffer,
        phase: ConstantOrBuffer,
        colour: f32, // 0-1, only used for square wave (TODO - use for tri/saw)
    };

    t: f32,

    pub fn init() Oscillator {
        return Oscillator {
            .t = 0.0,
        };
    }

    pub fn reset(self: *Oscillator) void {}

    pub fn paint(self: *Oscillator, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        // TODO - make params.colour ConstantOrBuffer as well...
        switch (params.freq) {
            .Constant => |freq|
                switch (params.phase) {
                    .Constant => |phase|
                        self.paintSimple(sample_rate, outputs[0], params.waveform, freq, params.colour),
                    .Buffer =>
                        @panic("TODO"), // FIXME
                },
            .Buffer => |freq|
                switch (params.phase) {
                    .Constant => |phase|
                        self.paintControlledFrequency(sample_rate, outputs[0], params.waveform, freq, params.colour),
                    .Buffer => |phase|
                        self.paintControlledPhaseAndFrequency(sample_rate, outputs[0], params.waveform, phase, freq, params.colour),
                },
        }
    }

    fn paintSimple(self: *Oscillator, sample_rate: f32, buf: []f32, waveform: Waveform, freq: f32, colour: f32) void {
        const step = freq / sample_rate;
        var t = self.t;
        var i: usize = 0;

        switch (waveform) {
            .Sine => {
                while (i < buf.len) : (i += 1) {
                    buf[i] += sin(t);
                    t += step;
                }
            },
            .Triangle => {
                while (i < buf.len) : (i += 1) {
                    buf[i] += tri(t);
                    t += step;
                }
            },
            .Square => {
                while (i < buf.len) : (i += 1) {
                    buf[i] += square(t, colour);
                    t += step;
                }
            },
            .Sawtooth => {
                while (i < buf.len) : (i += 1) {
                    buf[i] += saw(t);
                    t += step;
                }
            },
        }

        t -= std.math.trunc(t); // it actually goes out of tune without this!...

        self.t = t;
    }

    fn paintControlledFrequency(self: *Oscillator, sample_rate: f32, buf: []f32, waveform: Waveform, freq_buf: []const f32, colour: f32) void {
        const inv = 1.0 / sample_rate;
        var t = self.t;
        var i: usize = 0;

        switch (waveform) {
            .Sine => {
                while (i < buf.len) : (i += 1) {
                    const freq = freq_buf[i];
                    buf[i] += sin(t);
                    t += freq * inv;
                }
            },
            .Triangle => {
                while (i < buf.len) : (i += 1) {
                    const freq = freq_buf[i];
                    buf[i] += tri(t);
                    t += freq * inv;
                }
            },
            .Square => {
                while (i < buf.len) : (i += 1) {
                    const freq = freq_buf[i];
                    buf[i] += square(t, colour);
                    t += freq * inv;
                }
            },
            .Sawtooth => {
                while (i < buf.len) : (i += 1) {
                    const freq = freq_buf[i];
                    buf[i] += saw(t);
                    t += freq * inv;
                }
            },
        }

        t -= std.math.trunc(t); // it actually goes out of tune without this!...

        self.t = t;
    }

    fn paintControlledPhaseAndFrequency(
        self: *Oscillator,
        sample_rate: f32,
        buf: []f32,
        waveform: Waveform,
        input_phase: []const f32,
        input_frequency: []const f32,
        colour: f32,
    ) void {
        const inv = 1.0 / sample_rate;
        var t = self.t;
        var i: usize = 0;

        switch (waveform) {
            .Sine => {
                while (i < buf.len) : (i += 1) {
                    const phase = input_phase[i];
                    const freq = input_frequency[i];
                    buf[i] += sin(t + phase);
                    t += freq * inv;
                }
            },
            .Triangle => {
                while (i < buf.len) : (i += 1) {
                    const phase = input_phase[i];
                    const freq = input_frequency[i];
                    buf[i] += tri(t + phase);
                    t += freq * inv;
                }
            },
            .Square => {
                while (i < buf.len) : (i += 1) {
                    const phase = input_phase[i];
                    const freq = input_frequency[i];
                    buf[i] += square(t + phase, colour);
                    t += freq * inv;
                }
            },
            .Sawtooth => {
                while (i < buf.len) : (i += 1) {
                    const phase = input_phase[i];
                    const freq = input_frequency[i];
                    buf[i] += saw(t + phase);
                    t += freq * inv;
                }
            },
        }

        t -= std.math.trunc(t); // it actually goes out of tune without this!...

        self.t = t;
    }
};
