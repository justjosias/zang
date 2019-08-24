# zang todo

## Rename project
I don't like the new name either.

## New example: Record and play back notes played.
This one might be tricky. Add an example where you play some notes with the keyboard, then hit a button to say you're finished, then the program repeats what you played. To be clear: this should be done by recording the note events, not by using the delay audio effect.

Maybe like a loop pedal where you press to start, play some stuff, press to end, and it loops what you played, meanwhile you can keep playing on top of it.

## New module: bitcrusher
Make a module that lets you artificially alter the sample rate and resolution of the input stream.

Updated: I added decimator, which lets you change the sample rate, but doesn't do anything about the resolution, I guess that would be a separate module.

## Combine triangle and sawtooth oscillators and implement the "color" param
It will become TriSaw or something like that. When color is 0.5, it will be triangle. When color is 0 or 1, it will be a sawtooth.

## Alternate noise types
Zig's standard library has functions to generate random numbers with different distributions (`floatNorm` and `floatExp`), do those correspond to any "colors" of noise?

## Load configurations from text files
Drawbacks to creating sounds in the Zig API:
* verbose
* you have to manage temp buffers yourself
* have to recompile and reload to change something other than params (and params can only be changed on the fly if you've specifically programmed something to control it)

Making a text config format would solve these issues. I have these apprehensions:
* don't want to reinvent or compete with "music programming languages"
* lose the type safety of interacting with the configuration in Zig code

These can probably be dealt with. Against the first point, if I just stick to a declarative/functional config rather than a full programming language. Certainly no imperative stuff. Against the second point, I could generate Zig code for integration.

I could even compile the whole text config into Zig code, to continue to allow allocator-less usage. However this would mean maintaining two versions of the config compiler: one for on-the-fly usage, one to compile to Zig code.

What would the config look like? (I'm still calling it a config, but it may end up being more like a mini functional programming language.) I think similar to the how code using the Zig API looks, except reduced as much as possible.

## Delay length can't be chosen at runtime
Right now the delay effect uses a comptime sample count. This was to avoid having to dynamically allocate/reallocate the delay buffer. This was convenient while developing the other parts of the delay code, but now that that's all done, I need to address this.

The caller needs to be able to set the delay length to anything. Perhaps there could be a comptime limit, to avoid any dynamic allocations. That might be acceptable.

## Recognize when modules are "idle" and skip the paint method
Maybe as part of this, add an visual indicator to the examples of the number of "active" modules.

## Reimplement getImpulseFrame for examples
This is the function that tries to sync the timing of the main thread and the audio thread, so that when you press a key, the impulse is scheduled to play at an exact sample offset, which should be the time the key was pressed plus the duration of one mix buffer.

Right now I have all this code disabled so that all new sounds play at the beginning of the next mix buffer frame.

## Reset the phase of oscillators on every new note?
At least for square wave instruments this would probably be an improvement.

maybe just if there is a note-off and then a note-on.

## Polyphony: reset voice when slot is taken over
When a voice slot is taken over, don't just play a new note on it, somehow cause the reset method to be called. Otherwise e.g. the old note's envelope is resumed, noticeable for example if you have really slow attacks.

## Envelope release can be too loud if the note is released before decay has finished
For example, if you have a long release duration, and you release the note at the peak of the attack, you'll get a long, loud release, even if your attack & decay were both short and your sustain volume was low.

I guess I need to run the attack/decay alongside the release, and take the `min` of them or something.

## lo-fi zang
Make a second library which has only basic modules and doesn't use floats. Share as much as possible (API design and possibly even code).
