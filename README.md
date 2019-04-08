# harold
[Zig](https://ziglang.org/) audio playback and synth library, in need of a better name.

The core library (all there is right now) is very low-level. There are no dynamic allocations and the API is on the level of assembly programming (check out the "paint" functions in the examples). If I add higher level features, such as a declarative graph of audio modules, or a parsed text format representing arrangements or songs, they will be in separate libraries.

## Examples
All the examples use SDL2.

`zig build play`: You can play a simple synthesizer with the keyboard. Home row to play a C major scale, sharps/flats in the qwerty row. Hold space to play a low C in a separate voice.

`zig build song`: Plays a canned melody (first few bars of Bach's Toccata in D Minor).

`zig build subsong`: A small melody is played every time you hit the spacebar. The melody is encapsulated in a module, which looks on the outside like any other module (oscillators, etc).
