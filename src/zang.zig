const notes = @import("zang/notes.zig");
pub const IdGenerator = notes.IdGenerator;
pub const Impulse = notes.Impulse;
pub const Notes = notes.Notes;

const trigger = @import("zang/trigger.zig");
pub const ConstantOrBuffer = trigger.ConstantOrBuffer;
pub const constant = trigger.constant;
pub const buffer = trigger.buffer;
pub const Trigger = trigger.Trigger;

const mixdown = @import("zang/mixdown.zig");
pub const AudioFormat = mixdown.AudioFormat;
pub const mixDown = mixdown.mixDown;

const basics = @import("zang/basics.zig");
pub const Span = basics.Span;
pub const zero = basics.zero;
pub const set = basics.set;
pub const copy = basics.copy;
pub const add = basics.add;
pub const addInto = basics.addInto;
pub const addScalar = basics.addScalar;
pub const addScalarInto = basics.addScalarInto;
pub const multiply = basics.multiply;
pub const multiplyWith = basics.multiplyWith;
pub const multiplyScalar = basics.multiplyScalar;
pub const multiplyWithScalar = basics.multiplyWithScalar;

const painter = @import("zang/painter.zig");
pub const PaintCurve = painter.PaintCurve;
pub const PaintState = painter.PaintState;
pub const Painter = painter.Painter;

const delay = @import("zang/delay.zig");
pub const Delay = delay.Delay;

const mod_curve = @import("zang/mod_curve.zig");
pub const Curve = mod_curve.Curve;
pub const CurveNode = mod_curve.CurveNode;
pub const InterpolationFunction = mod_curve.InterpolationFunction;

const mod_decimator = @import("zang/mod_decimator.zig");
pub const Decimator = mod_decimator.Decimator;

const mod_distortion = @import("zang/mod_distortion.zig");
pub const Distortion = mod_distortion.Distortion;
pub const DistortionType = mod_distortion.DistortionType;

const mod_envelope = @import("zang/mod_envelope.zig");
pub const Envelope = mod_envelope.Envelope;

const mod_filter = @import("zang/mod_filter.zig");
pub const Filter = mod_filter.Filter;
pub const FilterType = mod_filter.FilterType;
pub const cutoffFromFrequency = mod_filter.cutoffFromFrequency;

const mod_gate = @import("zang/mod_gate.zig");
pub const Gate = mod_gate.Gate;

const mod_noise = @import("zang/mod_noise.zig");
pub const Noise = mod_noise.Noise;
pub const NoiseColor = mod_noise.NoiseColor;

const mod_portamento = @import("zang/mod_portamento.zig");
pub const Portamento = mod_portamento.Portamento;

const mod_pulseosc = @import("zang/mod_pulseosc.zig");
pub const PulseOsc = mod_pulseosc.PulseOsc;

const mod_sampler = @import("zang/mod_sampler.zig");
pub const Sampler = mod_sampler.Sampler;
pub const Sample = mod_sampler.Sample;
pub const SampleFormat = mod_sampler.SampleFormat;

const mod_sineosc = @import("zang/mod_sineosc.zig");
pub const SineOsc = mod_sineosc.SineOsc;

const mod_time = @import("zang/mod_time.zig");
pub const Time = mod_time.Time;

const mod_trisawosc = @import("zang/mod_trisawosc.zig");
pub const TriSawOsc = mod_trisawosc.TriSawOsc;
