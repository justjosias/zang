// this is the main file which is used by all examples.

const std = @import("std");
const zang = @import("zang");
const common = @import("common.zig");
const c = @import("common/c.zig");
const fft = @import("common/fft.zig").fft;
const example = @import(@import("build_options").example);

const AUDIO_FORMAT = example.AUDIO_FORMAT;
const AUDIO_SAMPLE_RATE = example.AUDIO_SAMPLE_RATE;
const AUDIO_BUFFER_SIZE = example.AUDIO_BUFFER_SIZE;

var g_outputs: [example.MainModule.num_outputs][AUDIO_BUFFER_SIZE]f32 = undefined;
var g_temps: [example.MainModule.num_temps][AUDIO_BUFFER_SIZE]f32 = undefined;

var g_redraw_event: c.Uint32 = undefined;

var g_fft_real = [1]f32{0.0} ** 1024;
var g_fft_imag = [1]f32{0.0} ** 1024;

var g_drawing = true;
var g_full_fft = false;
var g_fft_log = false;

const fontdata = @embedFile("font.dat");

const screen_w = 512;
const screen_h = 512;

fn pushRedrawEvent() void {
    var event: c.SDL_Event = undefined;
    event.type = g_redraw_event;
    _ = c.SDL_PushEvent(&event);
}

extern fn audioCallback(userdata_: ?*c_void, stream_: ?[*]u8, len_: c_int) void {
    const main_module = @ptrCast(*example.MainModule, @alignCast(@alignOf(*example.MainModule), userdata_.?));
    const stream = stream_.?[0..@intCast(usize, len_)];

    var outputs: [example.MainModule.num_outputs][]f32 = undefined;
    var temps: [example.MainModule.num_temps][]f32 = undefined;
    var i: usize = undefined;

    const span = zang.Span {
        .start = 0,
        .end = AUDIO_BUFFER_SIZE,
    };

    i = 0; while (i < example.MainModule.num_outputs) : (i += 1) {
        outputs[i] = g_outputs[i][0..];
        zang.zero(span, outputs[i]);
    }
    i = 0; while (i < example.MainModule.num_temps) : (i += 1) {
        temps[i] = g_temps[i][0..];
    }

    main_module.paint(span, outputs, temps);

    const mul = 0.25;

    i = 0; while (i < example.MainModule.num_outputs) : (i += 1) {
        zang.mixDown(stream, outputs[i][0..], AUDIO_FORMAT, example.MainModule.num_outputs, i, mul);
    }

    if (!g_drawing) {
        return;
    }

    // i = 0; while (i < example.MainModule.num_outputs) : (i += 1) {
    i = 0; {
        var j: usize = 0; while (j < AUDIO_BUFFER_SIZE / 1024) : (j += 1) {
            const output = outputs[i][j * 1024 .. j * 1024 + 1024];
            var min: f32 = 0.0;
            var max: f32 = 0.0;
            for (output) |sample| {
                if (sample < min) min = sample;
                if (sample > max) max = sample;
            }

            std.mem.copy(f32, g_fft_real[0..], output);
            std.mem.set(f32, g_fft_imag[0..], 0.0);
            fft(1024, g_fft_real[0..], g_fft_imag[0..]);

            c.plot(min * mul, max * mul, g_fft_real[0..].ptr, if (g_fft_log) c_int(1) else c_int(0));
        }
    }

    pushRedrawEvent();
}

pub fn main() !void {
    var main_module = example.MainModule.init();

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO) != 0) {
        c.SDL_Log(c"Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    errdefer c.SDL_Quit();

    g_redraw_event = c.SDL_RegisterEvents(1);

    const SDL_WINDOWPOS_UNDEFINED = @bitCast(c_int, c.SDL_WINDOWPOS_UNDEFINED_MASK);
    const window = c.SDL_CreateWindow(
        c"zang",
        SDL_WINDOWPOS_UNDEFINED,
        SDL_WINDOWPOS_UNDEFINED,
        screen_w, screen_h,
        0,
    ) orelse {
        c.SDL_Log(c"Unable to create window: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    errdefer c.SDL_DestroyWindow(window);

    const screen = c.SDL_GetWindowSurface(window);

    var want: c.SDL_AudioSpec = undefined;
    want.freq = AUDIO_SAMPLE_RATE;
    want.format = switch (AUDIO_FORMAT) {
        zang.AudioFormat.S8 => u16(c.AUDIO_S8),
        zang.AudioFormat.S16LSB => u16(c.AUDIO_S16LSB),
    };
    want.channels = example.MainModule.num_outputs;
    want.samples = AUDIO_BUFFER_SIZE;
    want.callback = audioCallback;
    want.userdata = &main_module;

    const device: c.SDL_AudioDeviceID = c.SDL_OpenAudioDevice(
        0, // device name (NULL)
        0, // non-zero to open for recording instead of playback
        &want, // desired output format
        0, // obtained output format (NULL)
        0, // allowed changes: 0 means `obtained` will not differ from `want`, and SDL will do any necessary resampling behind the scenes
    );
    if (device == 0) {
        c.SDL_Log(c"Failed to open audio: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    errdefer c.SDL_CloseAudio();

    // this seems to match the value of SDL_GetTicks the first time the audio
    // callback is called
    const start_time = @intToFloat(f32, c.SDL_GetTicks()) / 1000.0;

    c.SDL_PauseAudioDevice(device, 0); // unpause

    pushRedrawEvent();

    var event: c.SDL_Event = undefined;

    while (c.SDL_WaitEvent(&event) != 0) {
        switch (event.type) {
            c.SDL_QUIT => {
                break;
            },
            c.SDL_KEYDOWN,
            c.SDL_KEYUP => {
                const down = event.type == c.SDL_KEYDOWN;
                if (event.key.keysym.sym == c.SDLK_ESCAPE and down) {
                    break;
                }
                if (event.key.keysym.sym == c.SDLK_F1 and down) {
                    c.SDL_LockAudioDevice(device);
                    g_drawing = !g_drawing;
                    c.clear(window, screen, fontdata[0..].ptr, c"Press F1 to re-enable drawing");
                    c.SDL_UnlockAudioDevice(device);
                }
                if (event.key.keysym.sym == c.SDLK_F2 and down) {
                    g_full_fft = !g_full_fft;
                }
                if (event.key.keysym.sym == c.SDLK_F3 and down) {
                    g_fft_log = !g_fft_log;
                }
                if (@hasDecl(example.MainModule, "keyEvent")) {
                    if (event.key.repeat == 0) {
                        c.SDL_LockAudioDevice(device);
                        // const impulse_frame = getImpulseFrame(AUDIO_BUFFER_SIZE, AUDIO_SAMPLE_RATE, start_time);
                        const impulse_frame = getImpulseFrame();
                        main_module.keyEvent(event.key.keysym.sym, down, impulse_frame);
                        c.SDL_UnlockAudioDevice(device);
                    }
                }
            },
            c.SDL_MOUSEMOTION => {
                if (@hasDecl(example.MainModule, "mouseEvent")) {
                    const x = @intToFloat(f32, event.motion.x) / @intToFloat(f32, screen_w - 1);
                    const y = @intToFloat(f32, event.motion.y) / @intToFloat(f32, screen_h - 1);
                    const impulse_frame = getImpulseFrame();

                    c.SDL_LockAudioDevice(device);
                    main_module.mouseEvent(x, y, impulse_frame);
                    c.SDL_UnlockAudioDevice(device);
                }
            },
            else => {},
        }

        if (event.type == g_redraw_event) {
            c.SDL_LockAudioDevice(device);
            c.draw(window, screen, fontdata[0..].ptr, example.DESCRIPTION, if (g_full_fft) c_int(1) else c_int(0));
            c.SDL_UnlockAudioDevice(device);
        }
    }

    c.SDL_LockAudioDevice(device);
    c.SDL_UnlockAudioDevice(device);
    c.SDL_CloseAudioDevice(device);
    c.SDL_DestroyWindow(window);
    c.SDL_Quit();
}

// start notes at a random time within the mix buffer.
// this is only for testing purposes, because if i start everything at 0 there
// are some code paths not being hit.
// TODO - actually time the proper impulse frame
var r = std.rand.DefaultPrng.init(0);

fn getImpulseFrame() usize {
    // FIXME - i was using random values as a kind of test, but this is actually bad.
    // it means if you press two keys at the same time, they get different values, and
    // the second might have an earlier value than the first, which will cause it to
    // get discarded by the ImpulseQueue!
    // return r.random.intRangeLessThan(usize, 0, example.AUDIO_BUFFER_SIZE);

    return 0;
}

// // come up with a frame index to start the sound at
// fn getImpulseFrame(buffer_size: usize, sample_rate: usize, start_time: f32, current_frame_index: usize) usize {
//     // `current_frame_index` is the END of the mix frame currently queued to be heard next
//     const one_mix_frame = @intToFloat(f32, buffer_size) / @intToFloat(f32, sample_rate);

//     // time of the start of the mix frame currently underway
//     const mix_end = @intToFloat(f32, current_frame_index) / @intToFloat(f32, sample_rate);
//     const mix_start = mix_end - one_mix_frame;

//     const current_time = @intToFloat(f32, c.SDL_GetTicks()) / 1000.0 - start_time;

//     // if everything is working properly, current_time should be
//     // between mix_start and mix_end. there might be a little bit of an
//     // offset but i'm not going to deal with that for now.

//     // i just need to make sure that if this code queues up an impulse
//     // that's in the "past" when it actually gets picked up by the
//     // audio thread, it will still be picked up (somehow)!

//     // FIXME - shouldn't be multiplied by 2! this is only to
//     // compensate for the clocks sometimes starting out of sync
//     const impulse_time = current_time + one_mix_frame * 2.0;
//     const impulse_frame = @floatToInt(usize, impulse_time * @intToFloat(f32, sample_rate));

//     return impulse_frame;
// }
