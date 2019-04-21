// in this example you can trigger a laser sound effect by hitting the space bar

const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;
pub const AUDIO_CHANNELS = 1;

const LaserPlayer = struct {
    pub const NumTempBufs = 3;

    pub const InitParams = struct {
        carrier_mul: f32,
        modulator_mul: f32,
        modulator_rad: f32,
    };

    carrier_mul: f32,
    carrier_curve: zang.Curve,
    carrier: zang.Oscillator,
    modulator_mul: f32,
    modulator_rad: f32,
    modulator_curve: zang.Curve,
    modulator: zang.Oscillator,
    volume_curve: zang.Curve,

    fn init(params: InitParams) LaserPlayer {
        const A = 1000.0;
        const B = 200.0;
        const C = 100.0;

        return LaserPlayer {
            .carrier_mul = params.carrier_mul,
            .carrier_curve = zang.Curve.init(.SmoothStep, []zang.CurveNode {
                zang.CurveNode{ .t = 0.0, .value = A },
                zang.CurveNode{ .t = 0.1, .value = B },
                zang.CurveNode{ .t = 0.2, .value = C },
            }),
            .carrier = zang.Oscillator.init(.Sine),
            .modulator_mul = params.modulator_mul,
            .modulator_rad = params.modulator_rad,
            .modulator_curve = zang.Curve.init(.SmoothStep, []zang.CurveNode {
                zang.CurveNode{ .t = 0.0, .value = A },
                zang.CurveNode{ .t = 0.1, .value = B },
                zang.CurveNode{ .t = 0.2, .value = C },
            }),
            .modulator = zang.Oscillator.init(.Sine),
            .volume_curve = zang.Curve.init(.SmoothStep, []zang.CurveNode {
                zang.CurveNode{ .t = 0.0, .value = 0.0 },
                zang.CurveNode{ .t = 0.004, .value = 1.0 },
                zang.CurveNode{ .t = 0.2, .value = 0.0 },
            }),
        };
    }

    fn paint(self: *LaserPlayer, sample_rate: f32, out: []f32, note_on: bool, freq: f32, tmp: [NumTempBufs][]f32) void {
        const freq_mul = freq;

        zang.zero(tmp[0]);
        self.modulator_curve.paint(sample_rate, tmp[0], freq_mul * self.modulator_mul);
        zang.zero(tmp[1]);
        self.modulator.paintControlledFrequency(sample_rate, tmp[1], tmp[0]);
        zang.multiplyWithScalar(tmp[1], self.modulator_rad);
        zang.zero(tmp[0]);
        self.carrier_curve.paint(sample_rate, tmp[0], freq_mul * self.carrier_mul);
        zang.zero(tmp[2]);
        self.carrier.paintControlledPhaseAndFrequency(sample_rate, tmp[2], tmp[1], tmp[0]);
        zang.zero(tmp[0]);
        self.volume_curve.paint(sample_rate, tmp[0], null);
        zang.multiply(out, tmp[0], tmp[2]);
    }

    fn reset(self: *LaserPlayer) void {
        self.carrier_curve.reset();
        self.modulator_curve.reset();
        self.volume_curve.reset();
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    iq: zang.ImpulseQueue,
    laser_player: LaserPlayer,
    laser_trigger: zang.Trigger(LaserPlayer),

    r: std.rand.Xoroshiro128,

    pub fn init() MainModule {
        return MainModule{
            .iq = zang.ImpulseQueue.init(),
            // .laser_player = LaserPlayer.init(4.0, 0.125, 1.0), // enemy laser
            // .laser_player = LaserPlayer.init(0.5, 0.125, 1.0), // pain sound?
            // .laser_player = LaserPlayer.init(1.0, 9.0, 1.0), // some web effect?
            .laser_player = LaserPlayer.init(LaserPlayer.InitParams {
                // player laser
                .carrier_mul = 2.0,
                .modulator_mul = 0.5,
                .modulator_rad = 0.5,
            }),
            .laser_trigger = zang.Trigger(LaserPlayer).init(),
            .r = std.rand.DefaultPrng.init(0),
        };
    }

    pub fn paint(self: *MainModule) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];
        const tmp2 = g_buffers.buf3[0..];

        zang.zero(out);

        self.laser_trigger.paintFromImpulses(&self.laser_player, AUDIO_SAMPLE_RATE, out, self.iq.consume(), [3][]f32{tmp0, tmp1, tmp2});

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool) ?common.KeyEvent {
        if (key == c.SDLK_SPACE and down) {
            const base_freq = 1.0;
            const variance = 0.1;

            return common.KeyEvent{
                .iq = &self.iq,
                .freq = base_freq + self.r.random.float(f32) * variance - 0.5 * variance,
            };
        }

        return null;
    }
};
