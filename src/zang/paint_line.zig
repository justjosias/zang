pub const Painter = struct {
    pub const Curve = union(enum) {
        Instantaneous,
        Linear: f32, // duration (must be > 0)
        Squared: f32, // ditto
        Cubed: f32, // ditto
    };

    t: f32,
    last_value: f32,
    start: f32,

    pub fn init() Painter {
        return Painter {
            .t = 0.0,
            .last_value = 0.0,
            .start = 0.0,
        };
    }

    pub fn newCurve(self: *Painter) void {
        self.start = self.last_value;
        self.t = 0.0;
    }

    pub fn paintToward(self: *Painter, buf: []f32, i_ptr: *usize, sample_rate: f32, curve: Curve, goal: f32) bool {
        const CurveFunction = enum {
            Linear,
            Squared,
            Cubed,
        };

        if (self.t >= 1.0) {
            return true;
        }

        var curve_func: CurveFunction = undefined;
        var duration: f32 = undefined;
        switch (curve) {
            .Instantaneous => {
                self.t = 1.0;
                self.last_value = goal;
                return true;
            },
            .Linear  => |dur| { curve_func = .Linear;  duration = dur; },
            .Squared => |dur| { curve_func = .Squared; duration = dur; },
            .Cubed   => |dur| { curve_func = .Cubed;   duration = dur; },
        }

        var i = i_ptr.*;
        defer i_ptr.* = i;

        const t_step = 1.0 / (duration * sample_rate);
        var finished = false;

        // TODO - this can be optimized
        while (!finished and i < buf.len) : (i += 1) {
            self.t += t_step;
            if (self.t >= 1.0) {
                self.t = 1.0;
                finished = true;
            }
            const it = 1.0 - self.t;
            const tp = switch (curve_func) {
                .Linear => self.t,
                .Squared => 1.0 - it * it,
                .Cubed => 1.0 - it * it * it,
            };
            self.last_value = self.start + tp * (goal - self.start);
            buf[i] += self.last_value;
        }

        return finished;
    }
};
