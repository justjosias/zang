// filter implementation ripped from farbrausch's v2 (public domain)
// https://github.com/farbrausch/fr_public/blob/master/v2/LICENSE.txt
// https://github.com/farbrausch/fr_public/blob/master/v2/synth_core.cpp

const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;
const getNextNoteSpan = @import("note_span.zig").getNextNoteSpan;

const fcdcoffset: f32 = 3.814697265625e-6; // 2^-18

pub const FilterType = enum{
    Bypass,
    LowPass,
    BandPass,
    HighPass,
    Notch,
    AllPass,
};

pub const Filter = struct{
    filterType: FilterType,
    l: f32,
    b: f32,
    cutoff: f32,
    resonance: f32,

    pub fn init(filterType: FilterType, cutoff: f32, resonance: f32) Filter {
        return Filter{
            .filterType = filterType,
            .l = 0.0,
            .b = 0.0,
            .cutoff = cutoff,
            .resonance = resonance,
        };
    }

    pub fn paint(self: *Filter, sample_rate: u32, buf: []f32, input: []const f32) void {
        std.debug.assert(buf.len == input.len);

        var l_mul: f32 = 0.0;
        var b_mul: f32 = 0.0;
        var h_mul: f32 = 0.0;

        switch (self.filterType) {
            .Bypass => {
                std.mem.copy(f32, buf, input);
                return;
            },
            .LowPass => {
                l_mul = 1.0;
            },
            .BandPass => {
                b_mul = 1.0;
            },
            .HighPass => {
                h_mul = 1.0;
            },
            .Notch => {
                l_mul = 1.0;
                h_mul = 1.0;
            },
            .AllPass => {
                l_mul = 1.0;
                b_mul = 1.0;
                h_mul = 1.0;
            },
        }

        var i: usize = 0;

        const freq = blk: {
            var v: f32 = undefined;
            v = 2.0 * (1.0 - std.math.cos(std.math.pi * self.cutoff / @intToFloat(f32, sample_rate)));
            v = std.math.max(0.0, std.math.min(1.0, v));
            v = std.math.sqrt(v);
            break :blk v;
        };

        const res = 1.0 - std.math.max(0.0, std.math.min(1.0, self.resonance));

        var l = self.l;
        var b = self.b;
        var h: f32 = undefined;

        while (i < buf.len) : (i += 1) {
            // run 2x oversampled step

            // the filters get slightly biased inputs to avoid the state variables
            // getting too close to 0 for prolonged periods of time (which would
            // cause denormals to appear)
            const in = input[i] + fcdcoffset;

            // step 1
            l += freq * b - fcdcoffset; // undo bias here (1 sample delay)
            b += freq * (in - b * res - l);

            // step 2
            l += freq * b;
            h = in - b * res - l;
            b += freq * h;

            buf[i] += l * l_mul + b * b_mul + h * h_mul;
        }

        self.l = l;
        self.b = b;
    }

    pub fn paintFromImpulses(
        self: *Filter,
        sample_rate: u32,
        buf: []f32,
        input: []const f32,
        impulses: []const Impulse,
        frame_index: usize,
    ) void {
        std.debug.assert(buf.len == input.len);

        var start: usize = 0;

        while (start < buf.len) {
            const note_span = getNextNoteSpan(impulses, frame_index, start, buf.len);

            const buf_span = buf[note_span.start .. note_span.end];
            const input_span = input[note_span.start .. note_span.end];

            if (note_span.note) |note| {
                self.cutoff = note.freq;
            }

            self.paint(sample_rate, buf_span, input_span);

            start = note_span.end;
        }
    }

    // TODO - allow cutoff and resonance to be controlled
};
