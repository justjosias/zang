const std = @import("std");
const addInto = @import("basics.zig").addInto;
const multiplyWithScalar = @import("basics.zig").multiplyWithScalar;

// this delay module is not able to handle changes in sample rate, or changes
// in the delay time, so it's not quite ready for prime time. i need to figure
// out how to deal with reallocating(?) the delay buffer when the sample rate
// or delay time changes.
pub fn Delay(comptime DELAY_SAMPLES: usize) type {
    return struct {
        pub const NumOutputs = 1;
        pub const NumTemps = 0;
        pub const Params = struct {
            input: []const f32,
            feedback_level: f32, // 0-1
        };

        delay_buffer: [DELAY_SAMPLES]f32,
        delay_buffer_index: usize, // this will wrap around. always < DELAY_SAMPLES

        pub fn init() @This() {
            return @This() {
                .delay_buffer = [1]f32{0.0} ** DELAY_SAMPLES,
                .delay_buffer_index = 0,
            };
        }

        pub fn reset(self: *@This()) void {}

        pub fn paint(self: *@This(), sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
            const out = outputs[0];
            const buf_len = params.input.len; // this is the same as the output length

            // feedback_level > 1.0 is some fun you're not allowed to have.
            const feedback_level = clamp01(f32, params.feedback_level);

            // copy input to delay buffer and increment delay_buffer_index.
            if (buf_len <= DELAY_SAMPLES) {
                // we'll have to do this in up to two steps (in case we are
                // wrapping around the delay buffer)
                const len = min(usize, DELAY_SAMPLES - self.delay_buffer_index, buf_len);
                const delay_slice = self.delay_buffer[self.delay_buffer_index .. self.delay_buffer_index + len];

                // paint from delay buffer to output
                addInto(out[0..len], delay_slice);

                // decay delay buffer
                multiplyWithScalar(delay_slice, feedback_level);

                // paint from input into delay buffer
                addInto(delay_slice, params.input[0..len]);

                if (len < buf_len) {
                    // wrap around to the start of the delay buffer, and
                    // perform the same operations as above with the remaining
                    // part of the input/output
                    const b_len = buf_len - len;
                    addInto(out[len..], self.delay_buffer[0..b_len]);
                    multiplyWithScalar(self.delay_buffer[0..b_len], feedback_level);
                    addInto(self.delay_buffer[0..b_len], params.input[len..]);

                    self.delay_buffer_index = b_len;
                } else {
                    // wrapping not needed
                    self.delay_buffer_index += len;
                    if (self.delay_buffer_index == DELAY_SAMPLES) {
                        self.delay_buffer_index = 0;
                    }
                }
            } else {
                // the delay buffer is smaller than the input buffer.
                // we're going to have to loop or recurse
                self.paint(sample_rate, [1][]f32{out[0..DELAY_SAMPLES]}, [0][]f32{}, Params {
                    .input = params.input[0..DELAY_SAMPLES],
                    .feedback_level = params.feedback_level,
                });
                self.paint(sample_rate, [1][]f32{out[DELAY_SAMPLES..]}, [0][]f32{}, Params {
                    .input = params.input[DELAY_SAMPLES..],
                    .feedback_level = params.feedback_level,
                });
            }
        }
    };
}

inline fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}

inline fn clamp01(comptime T: type, v: T) T {
    return if (v < 0.0) 0.0 else if (v > 1.0) 1.0 else v;
}
