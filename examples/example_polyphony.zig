// this a "brute force" approach to polyphony... every possible note gets its
// own voice that is always running. well, it works
// also you can press spacebar to cycle through various levels of decimation

const std = @import("std");
const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");
const Instrument = @import("modules.zig").NiceInstrument;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

const A4 = 220.0;

const Polyphony = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;
    pub const Params = struct {
        note_held: [common.key_bindings.len]bool,
    };

    const Voice = struct {
        down: bool,
        iq: zang.Notes(Instrument.Params).ImpulseQueue,
        instr: zang.Triggerable(Instrument),
    };

    voices: [common.key_bindings.len]Voice,

    fn init() Polyphony {
        var self = Polyphony {
            .voices = undefined,
        };
        var i: usize = 0; while (i < common.key_bindings.len) : (i += 1) {
            self.voices[i] = Voice {
                .down = false,
                .iq = zang.Notes(Instrument.Params).ImpulseQueue.init(),
                .instr = zang.initTriggerable(Instrument.init()),
            };
        }
        return self;
    }

    fn reset(self: *Polyphony) void {}

    fn paint(self: *Polyphony, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        var i: usize = 0; while (i < common.key_bindings.len) : (i += 1) {
            if (params.note_held[i] != self.voices[i].down) {
                self.voices[i].iq.push(0, Instrument.Params {
                    .freq = A4 * common.key_bindings[i].rel_freq,
                    .note_on = params.note_held[i],
                });
                self.voices[i].down = params.note_held[i];
            }
        }

        for (self.voices) |*voice| {
            voice.instr.paintFromImpulses(sample_rate, outputs, temps, voice.iq.consume());
        }
    }
};

const MyDecimatorParams = struct {
    bypass: bool,
};

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 3;

    iq: zang.Notes(Polyphony.Params).ImpulseQueue,
    current_params: Polyphony.Params,
    polyphony: zang.Triggerable(Polyphony),
    dec: zang.Decimator,
    dec_mode: u32,

    pub fn init() MainModule {
        return MainModule{
            .iq = zang.Notes(Polyphony.Params).ImpulseQueue.init(),
            .current_params = Polyphony.Params {
                .note_held = [1]bool{false} ** common.key_bindings.len,
            },
            .polyphony = zang.initTriggerable(Polyphony.init()),
            .dec = zang.Decimator.init(),
            .dec_mode = 0,
        };
    }

    pub fn paint(self: *MainModule, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        const impulses = self.iq.consume();

        zang.zero(temps[2]);
        self.polyphony.paintFromImpulses(sample_rate, [1][]f32{temps[2]}, [2][]f32{temps[0], temps[1]}, impulses);

        if (self.dec_mode > 0) {
            self.dec.paint(sample_rate, outputs, [0][]f32{}, zang.Decimator.Params {
                .input = temps[2],
                .fake_sample_rate = switch (self.dec_mode) {
                    1 => f32(6000.0),
                    2 => f32(5000.0),
                    3 => f32(4000.0),
                    4 => f32(3000.0),
                    5 => f32(2000.0),
                    6 => f32(1000.0),
                    else => unreachable,
                },
            });
        } else {
            zang.addInto(outputs[0], temps[2]);
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (key == c.SDLK_SPACE and down) {
            self.dec_mode = (self.dec_mode + 1) % 7;
            return;
        }
        for (common.key_bindings) |kb, i| {
            if (kb.key == key) {
                self.current_params.note_held[i] = down;
                self.iq.push(impulse_frame, self.current_params);
            }
        }
    }
};
