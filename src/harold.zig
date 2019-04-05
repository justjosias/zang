pub const note_frequencies = @import("harold/note_frequencies.zig");

const compile_song = @import("harold/compile_song.zig");
pub const Note = compile_song.Note;
pub const compileSong = compile_song.compileSong;

const note_span = @import("harold/note_span.zig");
pub const Impulse = note_span.Impulse;
pub const getNextNoteSpan = note_span.getNextNoteSpan;

const impulse_queue = @import("harold/impulse_queue.zig");
pub const ImpulseQueue = impulse_queue.ImpulseQueue;

const mixdown = @import("harold/mixdown.zig");
pub const AudioFormat = mixdown.AudioFormat;
pub const mixDown = mixdown.mixDown;

const read_wav = @import("harold/read_wav.zig");
pub const readWav = read_wav.readWav;

const basics = @import("harold/basics.zig");
pub const zero = basics.zero;
pub const copy = basics.copy;
pub const add = basics.add;
pub const addInto = basics.addInto;
pub const multiply = basics.multiply;
pub const multiplyScalar = basics.multiplyScalar;

const mod_dc = @import("harold/mod_dc.zig");
pub const DC = mod_dc.DC;

const mod_envelope = @import("harold/mod_envelope.zig");
pub const EnvParams = mod_envelope.EnvParams;
pub const EnvState = mod_envelope.EnvState;
pub const Envelope = mod_envelope.Envelope;

const mod_filter = @import("harold/mod_filter.zig");
pub const Filter = mod_filter.Filter;
pub const FilterType = mod_filter.FilterType;

const mod_noise = @import("harold/mod_noise.zig");
pub const Noise = mod_noise.Noise;

const mod_oscillator = @import("harold/mod_oscillator.zig");
pub const Oscillator = mod_oscillator.Oscillator;
pub const Waveform = mod_oscillator.Waveform;

const mod_portamento = @import("harold/mod_portamento.zig");
pub const Portamento = mod_portamento.Portamento;

const mod_sampler = @import("harold/mod_sampler.zig");
pub const Sampler = mod_sampler.Sampler;
