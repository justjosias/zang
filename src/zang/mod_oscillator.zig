// TODO remove this as soon as PulseOsc and TriSawOsc are upgraded to support
// controlled frequency

const std = @import("std");
const ConstantOrBuffer = @import("trigger.zig").ConstantOrBuffer;
const Span = @import("basics.zig").Span;

pub const Waveform = enum {
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
    const frac = (t - std.math.floor(t)) * 2.0 - 1.0;
    return frac;
}

pub fn square(t: f32, color: f32) f32 {
    const frac = t - std.math.floor(t);
    return if (frac < color) f32(0.7) else f32(-0.7);
}

fn oscFunc(waveform: Waveform) fn (t: f32) f32 {
    return switch (waveform) {
        .Triangle => tri,
        .Square => square,
        .Sawtooth => saw,
    };
}

fn osc(waveform: Waveform, t: f32) f32 {
    return oscFunc(waveform)(t);
}

pub const Oscillator = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        sample_rate: f32,
        waveform: Waveform,
        freq: ConstantOrBuffer,
        color: f32, // 0-1, only used for square wave (TODO - use for tri/saw)
    };

    t: f32,

    pub fn init() Oscillator {
        return Oscillator {
            .t = 0.0,
        };
    }

    pub fn paint(self: *Oscillator, span: Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32, params: Params) void {
        const output = outputs[0][span.start..span.end];

        // TODO - make params.color ConstantOrBuffer as well...
        switch (params.freq) {
            .Constant => |freq|
                self.paintConstantFrequency(params.sample_rate, output, params.waveform, freq, params.color),
            .Buffer => |freq|
                self.paintControlledFrequency(params.sample_rate, output, params.waveform, freq[span.start..span.end], params.color),
        }
    }

    fn paintConstantFrequency(self: *Oscillator, sample_rate: f32, buf: []f32, waveform: Waveform, freq: f32, color: f32) void {
        const step = freq / sample_rate;
        var t = self.t;
        var i: usize = 0;

        switch (waveform) {
            .Triangle => {
                while (i < buf.len) : (i += 1) {
                    buf[i] += tri(t);
                    t += step;
                }
            },
            .Square => {
                while (i < buf.len) : (i += 1) {
                    buf[i] += square(t, color);
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

    fn paintControlledFrequency(self: *Oscillator, sample_rate: f32, buf: []f32, waveform: Waveform, freq_buf: []const f32, color: f32) void {
        const inv = 1.0 / sample_rate;
        var t = self.t;
        var i: usize = 0;

        switch (waveform) {
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
                    buf[i] += square(t, color);
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
};
