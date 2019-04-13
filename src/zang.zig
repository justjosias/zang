pub const note_frequencies = @import("zang/note_frequencies.zig");

const note_span = @import("zang/note_span.zig");
pub const Impulse = note_span.Impulse;
pub const getNextNoteSpan = note_span.getNextNoteSpan;

const curves = @import("zang/curves.zig");
pub const CurveNode = curves.CurveNode;
pub const getNextCurveNode = curves.getNextCurveNode;

const impulse_queue = @import("zang/impulse_queue.zig");
pub const ImpulseQueue = impulse_queue.ImpulseQueue;

const mixdown = @import("zang/mixdown.zig");
pub const AudioFormat = mixdown.AudioFormat;
pub const mixDown = mixdown.mixDown;

const read_wav = @import("zang/read_wav.zig");
pub const readWav = read_wav.readWav;

const basics = @import("zang/basics.zig");
pub const zero = basics.zero;
pub const copy = basics.copy;
pub const add = basics.add;
pub const addScalar = basics.addScalar;
pub const addInto = basics.addInto;
pub const multiply = basics.multiply;
pub const multiplyScalar = basics.multiplyScalar;
pub const multiplyWithScalar = basics.multiplyWithScalar;

const mod_curve = @import("zang/mod_curve.zig");
pub const Curve = mod_curve.Curve;
pub const InterpolationFunction = mod_curve.InterpolationFunction;

const mod_dc = @import("zang/mod_dc.zig");
pub const DC = mod_dc.DC;

const mod_envelope = @import("zang/mod_envelope.zig");
pub const EnvParams = mod_envelope.EnvParams;
pub const EnvState = mod_envelope.EnvState;
pub const Envelope = mod_envelope.Envelope;

const mod_filter = @import("zang/mod_filter.zig");
pub const Filter = mod_filter.Filter;
pub const FilterType = mod_filter.FilterType;

const mod_noise = @import("zang/mod_noise.zig");
pub const Noise = mod_noise.Noise;

const mod_oscillator = @import("zang/mod_oscillator.zig");
pub const Oscillator = mod_oscillator.Oscillator;
pub const Waveform = mod_oscillator.Waveform;

const mod_portamento = @import("zang/mod_portamento.zig");
pub const Portamento = mod_portamento.Portamento;

const mod_sampler = @import("zang/mod_sampler.zig");
pub const Sampler = mod_sampler.Sampler;
