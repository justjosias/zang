const std = @import("std");

const SEMITONE = std.math.pow(f32, 2.0, 1.0 / 12.0);

const A4_FREQUENCY = 440.0;

// note=0 is A4 (440hz)
// note=12 is A5
// etc.
fn calcNoteFreq(note: i32) f32 {
  return A4_FREQUENCY * std.math.pow(f32, SEMITONE, @intToFloat(f32, note));
}

pub const C3 = calcNoteFreq(-21);
pub const Cs3 = calcNoteFreq(-20);
pub const Db3 = calcNoteFreq(-20);
pub const D3 = calcNoteFreq(-19);
pub const Ds3 = calcNoteFreq(-18);
pub const Eb3 = calcNoteFreq(-18);
pub const E3 = calcNoteFreq(-17);
pub const F3 = calcNoteFreq(-16);
pub const Fs3 = calcNoteFreq(-15);
pub const Gb3 = calcNoteFreq(-15);
pub const G3 = calcNoteFreq(-14);
pub const Gs3 = calcNoteFreq(-13);
pub const Ab3 = calcNoteFreq(-13);
pub const A3 = calcNoteFreq(-12);
pub const As3 = calcNoteFreq(-11);
pub const Bb3 = calcNoteFreq(-11);
pub const B3 = calcNoteFreq(-10);
pub const C4 = calcNoteFreq(-9);
pub const Cs4 = calcNoteFreq(-8);
pub const Db4 = calcNoteFreq(-8);
pub const D4 = calcNoteFreq(-7);
pub const Ds4 = calcNoteFreq(-6);
pub const Eb4 = calcNoteFreq(-6);
pub const E4 = calcNoteFreq(-5);
pub const F4 = calcNoteFreq(-4);
pub const Fs4 = calcNoteFreq(-3);
pub const Gb4 = calcNoteFreq(-3);
pub const G4 = calcNoteFreq(-2);
pub const Gs4 = calcNoteFreq(-1);
pub const Ab4 = calcNoteFreq(-1);
pub const A4 = calcNoteFreq(0);
pub const As4 = calcNoteFreq(1);
pub const Bb4 = calcNoteFreq(1);
pub const B4 = calcNoteFreq(2);
pub const C5 = calcNoteFreq(3);
