# zang todo

## Rename project
I don't like the new name either.

## New example: Record and play back notes played.
This one might be tricky. Add an example where you play some notes with the keyboard, then hit a button to say you're finished, then the program repeats what you played. To be clear: this should be done by recording the note events, not by using the delay audio effect.

Maybe like a loop pedal where you press to start, play some stuff, press to end, and it loops what you played, meanwhile you can keep playing on top of it.

## New module: bitcrusher
Make a module that lets you artificially alter the sample rate and resolution of the input stream.

Updated: I added decimator, which lets you change the sample rate, but doesn't do anything about the resolution, I guess that would be a separate module.

## Alternate noise types
Zig's standard library has functions to generate random numbers with different distributions (`floatNorm` and `floatExp`), do those correspond to any "colors" of noise?

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

## PulseOsc with controlled frequency needs antialiasing

## TriSawOsc with controlled frequency needs total rewrite
