// this is the main file which is used by all examples.

const std = @import("std");
const zang = @import("zang");
const common = @import("examples/common.zig");
const c = @import("examples/common/sdl.zig");
const example = @import(@import("build_options").example);

const AUDIO_FORMAT = example.AUDIO_FORMAT;
const AUDIO_SAMPLE_RATE = example.AUDIO_SAMPLE_RATE;
const AUDIO_BUFFER_SIZE = example.AUDIO_BUFFER_SIZE;
const AUDIO_CHANNELS = example.AUDIO_CHANNELS;

extern fn audioCallback(userdata_: ?*c_void, stream_: ?[*]u8, len_: c_int) void {
    const main_module = @ptrCast(*example.MainModule, @alignCast(@alignOf(*example.MainModule), userdata_.?));
    const stream = stream_.?[0..@intCast(usize, len_)];

    const buffers = main_module.paint();

    for (buffers) |buf, i| {
        zang.mixDown(stream, buf, AUDIO_FORMAT, AUDIO_CHANNELS, i, 0.25);
    }
}

pub fn main() !void {
    var main_module = example.MainModule.init();

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO) != 0) {
        c.SDL_Log(c"Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    errdefer c.SDL_Quit();

    const SDL_WINDOWPOS_UNDEFINED = @bitCast(c_int, c.SDL_WINDOWPOS_UNDEFINED_MASK);
    const window = c.SDL_CreateWindow(
        c"zang",
        SDL_WINDOWPOS_UNDEFINED,
        SDL_WINDOWPOS_UNDEFINED,
        640, 480,
        0,
    ) orelse {
        c.SDL_Log(c"Unable to create window: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    errdefer c.SDL_DestroyWindow(window);

    var want: c.SDL_AudioSpec = undefined;
    want.freq = AUDIO_SAMPLE_RATE;
    want.format = switch (AUDIO_FORMAT) {
        zang.AudioFormat.S8 => u16(c.AUDIO_S8),
        zang.AudioFormat.S16LSB => u16(c.AUDIO_S16LSB),
    };
    want.channels = AUDIO_CHANNELS;
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

    var event: c.SDL_Event = undefined;

    while (c.SDL_WaitEvent(&event) != 0) {
        switch (event.type) {
            c.SDL_QUIT => {
                break;
            },
            c.SDL_KEYDOWN => {
                if (event.key.keysym.sym == c.SDLK_ESCAPE) {
                    break;
                }
                if (event.key.repeat == 0) {
                    if (main_module.keyEvent(event.key.keysym.sym, true)) |evt| {
                        c.SDL_LockAudioDevice(device);
                        const impulse_frame = getImpulseFrame(AUDIO_BUFFER_SIZE, AUDIO_SAMPLE_RATE, start_time, main_module.frame_index);
                        evt.iq.push(impulse_frame, evt.freq, main_module.frame_index);
                        c.SDL_UnlockAudioDevice(device);
                    }
                }
            },
            c.SDL_KEYUP => {
                if (main_module.keyEvent(event.key.keysym.sym, false)) |evt| {
                    c.SDL_LockAudioDevice(device);
                    const impulse_frame = getImpulseFrame(AUDIO_BUFFER_SIZE, AUDIO_SAMPLE_RATE, start_time, main_module.frame_index);
                    evt.iq.push(impulse_frame, evt.freq, main_module.frame_index);
                    c.SDL_UnlockAudioDevice(device);
                }
            },
            else => {},
        }
    }

    c.SDL_LockAudioDevice(device);
    c.SDL_UnlockAudioDevice(device);
    c.SDL_CloseAudioDevice(device);
    c.SDL_DestroyWindow(window);
    c.SDL_Quit();
}

// come up with a frame index to start the sound at
fn getImpulseFrame(buffer_size: usize, sample_rate: usize, start_time: f32, current_frame_index: usize) usize {
    // `current_frame_index` is the END of the mix frame currently queued to be heard next
    const one_mix_frame = @intToFloat(f32, buffer_size) / @intToFloat(f32, sample_rate);

    // time of the start of the mix frame currently underway
    const mix_end = @intToFloat(f32, current_frame_index) / @intToFloat(f32, sample_rate);
    const mix_start = mix_end - one_mix_frame;

    const current_time = @intToFloat(f32, c.SDL_GetTicks()) / 1000.0 - start_time;

    // if everything is working properly, current_time should be
    // between mix_start and mix_end. there might be a little bit of an
    // offset but i'm not going to deal with that for now.

    // i just need to make sure that if this code queues up an impulse
    // that's in the "past" when it actually gets picked up by the
    // audio thread, it will still be picked up (somehow)!

    // FIXME - shouldn't be multiplied by 2! this is only to
    // compensate for the clocks sometimes starting out of sync
    const impulse_time = current_time + one_mix_frame * 2.0;
    const impulse_frame = @floatToInt(usize, impulse_time * @intToFloat(f32, sample_rate));

    return impulse_frame;
}
