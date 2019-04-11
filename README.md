# harold
[Zig](https://ziglang.org/) audio library in need of a better name.

This library provides functions to "paint" audio (generators and effects) into buffers. (How the buffers get sent to the audio device is out of the scope of the library, but can be seen in the provided examples.)

The library is very low-level. There are no dynamic allocations and the API is on the level of assembly programming (check out the "paint" functions in the examples). If I add higher level features, such as a declarative graph of audio modules, or a parsed text format representing arrangements or songs, they will be separate libraries that build off of this one.

## Examples
All the examples use [SDL2](https://www.libsdl.org/), so make sure that's installed. The library is built on the latest (master) version of Zig.

`zig build play`: You can play a simple synthesizer with the keyboard. Home row to play a C major scale, sharps/flats in the qwerty row. Hold space to play a low C in a separate voice.

`zig build song`: Plays the first few bars of Bach's Toccata in D Minor.

`zig build subsong`: Like `play`, but a small melody is played for each note, pitched by the frequency of the key you press. The melody is encapsulated in a module, which looks on the outside like any other module (oscillators, etc).

`zig build stereo`: A wind-like filtered noise effect slowly oscillates from side to side. (Probably too subtle to be a good stereo demonstration, you might need headphones to even notice it.)

`zig build curve`: Like `subsong`, but plays a sound defined by smooth curves instead of discrete notes.

## Features
Modules:
* Curve: renders a curve (array of curve nodes) to a buffer using one of several interpolation functions
* DC: just a way to paint incoming note frequencies into a buffer
* Envelope: ADSR (attack, decay, sustain, release) envelope generator
* Filter: lowpass, highpass, notch, bandpass, including resonance
* Noise: basic white noise
* Oscillator: generate a sine, triangle, sawtooth, or triangle wave
* Portamento: interpolate the frequency of an incoming stream of notes
* Sampler: play an audio file (wav loader provided), resampling according to the note frequencies

The APIs of various modules aren't consistent. For example, some support parameters to be controlled by an input buffer (for example, the oscillator's frequency). Others only support being controlled by discrete notes. Some support both. This should be improved.

## Goals
My goals for the core library:
* Small set of standard generators and filters
* Decent audio quality (deal with oscillator aliasing, wav resampling...)
* Total modularity (single-purpose modules with controllable inputs)
* Clean API (somehow get rid of stuff like `paintControlledFrequencyAndPhase`)
* Ability to play music
* Ability to provide sound effects for a game
* Idiomatic Zig API
* Lean inner loops
* Overall small and simple codebase
* Documentation
* There was another one but I forgot

The library is currently 1400 lines of code. A lot of the above is already in there, although it needs to be cleaned up. And it already contains some fat that could be trimmed. I don't see the library getting much bigger than say 2500 lines of code, assuming not many more modules are added.

What needs the most work (other than the API surface in general) is how to make tracks or songs. Currently, songs contain notes that set a frequency. That's it. The notes should be able to set other parameters. This applies also to curves, and to notes created on the fly in interactive applications.

## Roadmap
I want to polish up this library fairly soon. There are more modules I could add (e.g. delay) but I would rather move on to a second library providing more high-level features (stack or graph based system with dynamic allocations, and/or a text config language with a player app that autorefreshes when the text file is changed).
