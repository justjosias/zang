const zang = @import("zang");

// to use a script module from zig code, you must provide a Params type that's
// compatible with the script.
// script module will come up with its own number of required temps, and you'll
// need to provide those, too. it will be known only at runtime, i think.

pub fn ScriptModule(comptime filename: []const u8, comptime ParamsType: type) type {
    return struct {
        pub const num_outputs = 1; // FIXME
        pub const num_temps = 0; // FIXME
        pub const Params = ParamsType;

        pub fn init() @This() {
            return .{};
        }

        pub fn paint(
            self: *@This(),
            span: Span,
            outputs: [num_outputs][]f32,
            temps: [num_temps][]f32,
            params: Params,
        ) void {
            const output = outputs[0];

            const gain1 = std.math.pow(f32, 2.0, params.ingain * 8.0 - 2.0);

            switch (params.distortion_type) {
                .overdrive => {
                    const gain2 = params.outgain / std.math.atan(gain1);
                    const offs = gain1 * params.offset;

                    var i = span.start;
                    while (i < span.end) : (i += 1) {
                        const a = std.math.atan(params.input[i] * gain1 + offs);
                        output[i] += gain2 * a;
                    }
                },
                .clip => {
                    const gain2 = params.outgain;
                    const offs = gain1 * params.offset;

                    var i = span.start;
                    while (i < span.end) : (i += 1) {
                        const a = params.input[i] * gain1 + offs;
                        const b = if (a < -1.0) -1.0 else if (a > 1.0) 1.0 else a;
                        output[i] += gain2 * b;
                    }
                },
            }
        }
    };
}
