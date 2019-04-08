# harold
[Zig](https://ziglang.org/) audio playback and synth library, in need of a better name.

The core library (all there is right now) is very low-level. There are no dynamic allocations and the API is on the level of assembly programming (check out the "paint" functions in the examples). If I add higher level features, such as a declarative graph of audio modules, or a parsed text format representing arrangements or songs, they will be separate libraries.

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
* Overall small codebase
* Documentation

The library is currently 1400 lines of code. A lot of the above is already in there, although it needs to be cleaned up. And it already contains some fat that could be trimmed. I don't see the library getting much bigger than say 2500 lines of code, assuming not many more modules are added.

What needs the most work is how to make tracks or songs. Currently, songs contain notes that set a frequency. That's it. The notes should be able to set other parameters. And then you should also be able to make tracks containing curves instead of notes, e.g. something to alter a filter cutoff over a long period of time.

(The above paragraph applies equally to "notes" and curves created on the fly in interactive applications.)

## Examples
All the examples use SDL2.

`zig build play`: You can play a simple synthesizer with the keyboard. Home row to play a C major scale, sharps/flats in the qwerty row. Hold space to play a low C in a separate voice.

`zig build song`: Plays the first few bars of Bach's Toccata in D Minor.

`zig build subsong`: Like `play`, but a small melody is played for each note, pitched by the frequency of the key you press. The melody is encapsulated in a module, which looks on the outside like any other module (oscillators, etc).
