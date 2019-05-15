const notes = @import("zang/notes.zig");
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

const read_wav = @import("zang/read_wav.zig");
pub const WavContents = read_wav.WavContents;
pub const readWav = read_wav.readWav;

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

const delay = @import("zang/delay.zig");
pub const Delay = delay.Delay;

const mod_curve = @import("zang/mod_curve.zig");
pub const Curve = mod_curve.Curve;
pub const CurveNode = mod_curve.CurveNode;
pub const InterpolationFunction = mod_curve.InterpolationFunction;

const mod_dc = @import("zang/mod_dc.zig");
pub const DC = mod_dc.DC;

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

const mod_oscillator = @import("zang/mod_oscillator.zig");
pub const Oscillator = mod_oscillator.Oscillator;
pub const Waveform = mod_oscillator.Waveform;

const mod_portamento = @import("zang/mod_portamento.zig");
pub const Portamento = mod_portamento.Portamento;

const mod_pulseosc = @import("zang/mod_pulseosc.zig");
pub const PulseOsc = mod_pulseosc.PulseOsc;

const mod_sampler = @import("zang/mod_sampler.zig");
pub const Sampler = mod_sampler.Sampler;
