const std = @import("std");
const fft = @import("common/fft.zig").fft;
const Recorder = @import("recorder.zig").Recorder;

const fontdata = @embedFile("font.dat");

pub const fontchar_w = 8;
pub const fontchar_h = 13;

pub fn drawString(start_x: usize, start_y: usize, pixels: []u32, pitch: usize, s: []const u8) void {
    const color: u32 = 0xAAAAAAAA;

    // warning: does no checking for drawing off screen
    var x = start_x;
    var y = start_y;
    for (s) |ch| {
        if (ch == '\n') {
            x = start_x;
            y += fontchar_h + 1;
        } else if (ch >= 32) {
            const index = @intCast(usize, ch - 32) * fontchar_h;
            var sy: usize = 0;
            while (sy < fontchar_h) : (sy += 1) {
                var sx: usize = 0;
                while (sx < fontchar_w) : (sx += 1) {
                    if ((fontdata[index + sy] & (@as(u8, 1) << @intCast(u3, sx))) != 0) {
                        pixels[(y + sy) * pitch + x + sx] = color;
                    }
                }
            }
            x += fontchar_w + 1;
        }
    }
}

fn hueToRgb(p: f32, q: f32, t_: f32) f32 {
    var t = t_;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

fn hslToRgb(h: f32, s: f32, l: f32) u32 {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;

    if (s == 0.0) {
        r = 1.0;
        g = 1.0;
        b = 1.0;
    } else {
        const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
        const p = 2 * l - q;
        r = hueToRgb(p, q, h + 1.0 / 3.0);
        g = hueToRgb(p, q, h);
        b = hueToRgb(p, q, h - 1.0 / 3.0);
    }

    // kludge
    const sqrt_h = std.math.sqrt(h);
    r *= sqrt_h;
    g *= sqrt_h;
    b *= sqrt_h;

    return @as(u32, 0xFF000000) |
        (@floatToInt(u32, b * 255) << 16) |
        (@floatToInt(u32, g * 255) << 8) |
        (@floatToInt(u32, r * 255));
}

fn scrollBlit(pixels: []u32, pitch: usize, x: usize, y: usize, w: usize, h: usize, buffer: []const u32, drawindex: usize) void {
    var i: usize = 0;
    while (i < h) : (i += 1) {
        const dest_start = (y + i) * pitch + x;
        const dest = pixels[dest_start .. dest_start + w];

        const src_start = i * w;
        const src = buffer[src_start .. src_start + w];

        std.mem.copy(u32, dest[w - drawindex ..], src[0..drawindex]);
        std.mem.copy(u32, dest[0 .. w - drawindex], src[drawindex..]);
    }
}

fn getFFTValue(f_: f32, in_fft: []const f32, logarithmic: bool) f32 {
    var f = f_;

    if (logarithmic) {
        const exp = 10.0;
        f = (std.math.pow(f32, exp, f) - 1.0) / (exp - 1.0);
    }

    f *= 511.5;
    const f_floor = std.math.floor(f);
    const index0 = @floatToInt(usize, f_floor);
    const index1 = std.math.min(511, index0 + 1);
    const frac = f - f_floor;

    const fft_value0 = in_fft[index0];
    const fft_value1 = in_fft[index1];

    return fft_value0 * (1.0 - frac) + fft_value1 * frac;
}

// area chart where x=frequency and y=amplitude
pub const DrawSpectrum = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    old_y: []u32,
    fft_value: []f32,
    logarithmic: bool,
    state: enum { up_to_date, needs_blit, needs_full_reblit },

    pub fn init(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !DrawSpectrum {
        var self: DrawSpectrum = .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .old_y = try allocator.alloc(u32, width),
            .fft_value = try allocator.alloc(f32, 512),
            .logarithmic = false,
            .state = .needs_full_reblit,
        };
        // old_y doesn't need to be initialized as long as state is .needs_full_reblit
        std.mem.set(f32, self.fft_value, 0.0);
        return self;
    }

    pub fn deinit(self: *DrawSpectrum, allocator: *std.mem.Allocator) void {
        allocator.free(self.old_y);
        allocator.free(self.fft_value);
    }

    pub fn reset(self: *DrawSpectrum) void {
        self.state = .needs_full_reblit;
        std.mem.set(f32, self.fft_value, 0.0);
    }

    pub fn plot(self: *DrawSpectrum, in_fft: *[1024]f32, logarithmic: bool) void {
        var i: usize = 0;
        while (i < 512) : (i += 1) {
            const v = std.math.fabs(in_fft[i]) * (1.0 / 1024.0);
            const v2 = std.math.sqrt(v); // kludge for visibility
            self.fft_value[i] = v2;
        }

        self.logarithmic = logarithmic;
        if (self.state == .up_to_date) {
            self.state = .needs_blit;
        }
    }

    pub fn blit(self: *DrawSpectrum, pixels: []u32, pitch: usize) void {
        if (self.state == .up_to_date) return;
        defer self.state = .up_to_date;

        const background_color: u32 = 0x00000000;
        const color: u32 = 0xFF444444;

        var i: usize = 0;
        while (i < self.width) : (i += 1) {
            const fi = @intToFloat(f32, i) / @intToFloat(f32, self.width - 1);
            const fv = getFFTValue(fi, self.fft_value, self.logarithmic) * @intToFloat(f32, self.height);

            const value = @floatToInt(u32, std.math.floor(fv));
            const value_clipped = std.math.min(value, self.height - 1);

            // new_y is where the graph will transition from background to foreground color
            const new_y = @intCast(u32, self.height - value_clipped);

            // the transition pixel will have a blended color value
            const frac = fv - std.math.floor(fv);
            const co: u32 = @floatToInt(u32, 0x44 * frac);
            const transition_color = @as(u32, 0xFF000000) | (co << 16) | (co << 8) | co;

            const sx = self.x + i;
            var sy = self.y;
            if (self.state == .needs_full_reblit) {
                // redraw fully
                while (sy < self.y + new_y) : (sy += 1) {
                    pixels[sy * pitch + sx] = background_color;
                }
                if (sy < self.y + self.height) {
                    pixels[sy * pitch + sx] = transition_color;
                    sy += 1;
                }
                while (sy < self.y + self.height) : (sy += 1) {
                    pixels[sy * pitch + sx] = color;
                }
            } else {
                const old_y = self.old_y[i];
                if (old_y < new_y) {
                    // new_y is lower down. fill in the overlap with background color
                    sy += old_y;
                    while (sy < self.y + new_y) : (sy += 1) {
                        pixels[sy * pitch + sx] = background_color;
                    }
                    if (sy < self.y + self.height) {
                        pixels[sy * pitch + sx] = transition_color;
                        sy += 1;
                    }
                } else if (old_y > new_y) {
                    // new_y is higher up. fill in the overlap with foreground color
                    sy += new_y;
                    if (sy < self.y + self.height) {
                        pixels[sy * pitch + sx] = transition_color;
                        sy += 1;
                    }
                    // add one to cover up the old transition pixel
                    const until = std.math.min(old_y + 1, self.height);
                    while (sy < self.y + until) : (sy += 1) {
                        pixels[sy * pitch + sx] = color;
                    }
                }
            }

            self.old_y[i] = new_y;
        }
    }
};

// scrolling 2d color plot of FFT data
pub const DrawSpectrumFull = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    buffer: []u32,
    logarithmic: bool,
    drawindex: usize,

    pub fn init(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !DrawSpectrumFull {
        var self: DrawSpectrumFull = .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .buffer = try allocator.alloc(u32, width * height),
            .logarithmic = false,
            .drawindex = 0,
        };
        std.mem.set(u32, self.buffer, 0);
        return self;
    }

    pub fn deinit(self: *DrawSpectrumFull, allocator: *std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn reset(self: *DrawSpectrumFull) void {
        std.mem.set(u32, self.buffer, 0.0);
        self.drawindex = 0;
    }

    pub fn plot(self: *DrawSpectrumFull, in_fft: *[1024]f32, logarithmic: bool) void {
        if (self.logarithmic != logarithmic) {
            self.logarithmic = logarithmic;
            self.reset();
        }

        var i: usize = 0;
        while (i < self.height) : (i += 1) {
            const f = @intToFloat(f32, i) / @intToFloat(f32, self.height - 1);
            const fft_value = getFFTValue(f, in_fft, logarithmic);

            // sqrt is a kludge to make things more visible
            const v = std.math.sqrt(std.math.fabs(fft_value) * (1.0 / 1024.0));

            self.buffer[(self.height - 1 - i) * self.width + self.drawindex] = hslToRgb(v, 1.0, 0.5);
        }

        self.drawindex += 1;
        if (self.drawindex == self.width) {
            self.drawindex = 0;
        }
    }

    pub fn blit(self: *DrawSpectrumFull, pixels: []u32, pitch: usize) void {
        scrollBlit(pixels, pitch, self.x, self.y, self.width, self.height, self.buffer, self.drawindex);
    }
};

// scrolling waveform view
pub const DrawWaveform = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    buffer: []u32,
    drawindex: usize,
    dirty: bool,

    const background_color: u32 = 0x18181818;
    const waveform_color: u32 = 0x44444444;
    const clipped_color: u32 = 0xFFFF0000;
    const center_line_color: u32 = 0x66666666;

    pub fn init(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !DrawWaveform {
        return DrawWaveform{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .buffer = try allocator.alloc(u32, width * height),
            .drawindex = 0,
            .dirty = true,
        };
    }

    pub fn deinit(self: *DrawWaveform, allocator: *std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn reset(self: *DrawWaveform) void {
        std.mem.set(u32, self.buffer, background_color);

        const start = self.height / 2 * self.width;
        const end = start + self.width;
        std.mem.set(u32, self.buffer[start..end], center_line_color);

        self.dirty = true;
        self.drawindex = 0;
    }

    pub fn plot(self: *DrawWaveform, sample_min: f32, sample_max: f32) void {
        const y_mid = self.height / 2;
        const sample_min_clipped = std.math.max(-1.0, sample_min);
        const sample_max_clipped = std.math.min(1.0, sample_max);
        var y0 = @floatToInt(usize, @intToFloat(f32, y_mid) - sample_max * @intToFloat(f32, self.height / 2) + 0.5);
        var y1 = @floatToInt(usize, @intToFloat(f32, y_mid) - sample_min * @intToFloat(f32, self.height / 2) + 0.5);
        var sx = self.drawindex;
        var sy: usize = 0;
        var until: usize = undefined;

        if (sample_max >= 1.0) {
            self.buffer[sy * self.width + sx] = clipped_color;
            sy += 1;
        }
        until = std.math.min(y0, y_mid);
        while (sy < until) : (sy += 1) {
            self.buffer[sy * self.width + sx] = background_color;
        }
        until = std.math.min(y1, y_mid);
        while (sy < until) : (sy += 1) {
            self.buffer[sy * self.width + sx] = waveform_color;
        }
        while (sy < y_mid) : (sy += 1) {
            self.buffer[sy * self.width + sx] = background_color;
        }
        self.buffer[sy * self.width + sx] = center_line_color;
        sy += 1;
        if (y0 > y_mid) {
            until = std.math.min(y0, self.height);
            while (sy < until) : (sy += 1) {
                self.buffer[sy * self.width + sx] = background_color;
            }
        }
        until = std.math.min(y1, self.height);
        while (sy < until) : (sy += 1) {
            self.buffer[sy * self.width + sx] = waveform_color;
        }
        while (sy < self.height) : (sy += 1) {
            self.buffer[sy * self.width + sx] = background_color;
        }
        if (sample_min <= -1.0) {
            sy -= 1;
            self.buffer[sy * self.width + sx] = background_color;
        }

        self.dirty = true;
        self.drawindex += 1;
        if (self.drawindex == self.width) {
            self.drawindex = 0;
        }
    }

    pub fn blit(self: *DrawWaveform, pixels: []u32, pitch: usize) void {
        if (!self.dirty) return;
        self.dirty = false;

        scrollBlit(pixels, pitch, self.x, self.y, self.width, self.height, self.buffer, self.drawindex);
    }
};

pub const DrawRecorderState = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    recorder_state: @TagType(Recorder.State),

    pub fn init(x: usize, y: usize, width: usize, height: usize) DrawRecorderState {
        return DrawRecorderState{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .recorder_state = .idle,
        };
    }

    pub fn reset(self: *DrawRecorderState) void {
        self.recorder_state = .idle;
    }

    pub fn blit(self: *DrawRecorderState, pixels: []u32, pitch: usize, recorder_state: @TagType(Recorder.State)) void {
        if (self.recorder_state == recorder_state) return;
        self.recorder_state = recorder_state;

        var i: usize = 0;
        while (i < self.height) : (i += 1) {
            const start = (self.y + i) * pitch + self.x;
            const end = start + self.width;
            std.mem.set(u32, pixels[start..end], 0);
        }

        drawString(self.x, self.y, pixels, pitch, switch (recorder_state) {
            .idle => "",
            .recording => "RECORDING",
            .playing => "PLAYING BACK",
        });
    }
};

pub const Visuals = struct {
    fft_real: []f32,
    fft_imag: []f32,

    draw_waveform: DrawWaveform,
    draw_spectrum: DrawSpectrum,
    draw_spectrum_full: DrawSpectrumFull,
    draw_recorder_state: DrawRecorderState,

    disabled: bool,
    full_fft_view: bool,
    logarithmic_fft: bool,

    redraw_all: bool,

    pub fn init(allocator: *std.mem.Allocator, screen_w: usize, screen_h: usize) !Visuals {
        const fft_height = 128;
        const waveform_height = 81;
        const bottom_padding = fontchar_h;

        var draw_waveform = try DrawWaveform.init(allocator, 0, screen_h - bottom_padding - waveform_height, screen_w, waveform_height);
        errdefer draw_waveform.deinit(allocator);
        var draw_spectrum = try DrawSpectrum.init(allocator, 0, screen_h - bottom_padding - waveform_height - fft_height, screen_w, fft_height);
        errdefer draw_spectrum.deinit(allocator);
        var draw_spectrum_full = try DrawSpectrumFull.init(allocator, 0, 0, screen_w, screen_h);
        errdefer draw_spectrum_full.deinit(allocator);
        var draw_recorder_state = DrawRecorderState.init(0, screen_h - fontchar_h, screen_w, fontchar_h);

        return Visuals{
            .fft_real = try allocator.alloc(f32, 1024),
            .fft_imag = try allocator.alloc(f32, 1024),
            .draw_waveform = draw_waveform,
            .draw_spectrum = draw_spectrum,
            .draw_spectrum_full = draw_spectrum_full,
            .draw_recorder_state = draw_recorder_state,
            .disabled = false,
            .full_fft_view = false,
            .logarithmic_fft = false,
            .redraw_all = true,
        };
    }

    pub fn deinit(self: *Visuals, allocator: *std.mem.Allocator) void {
        allocator.free(self.fft_real);
        allocator.free(self.fft_imag);
        self.draw_waveform.deinit(allocator);
        self.draw_spectrum.deinit(allocator);
        self.draw_spectrum_full.deinit(allocator);
    }

    pub fn toggleDisabled(self: *Visuals) void {
        self.disabled = !self.disabled;
        self.redraw_all = true;
    }

    pub fn toggleFullFFTView(self: *Visuals) void {
        self.full_fft_view = !self.full_fft_view;
        self.redraw_all = true;
    }

    pub fn toggleLogarithmicFFT(self: *Visuals) void {
        self.logarithmic_fft = !self.logarithmic_fft;
    }

    // called on the audio thread
    pub fn newInput(self: *Visuals, samples: []const f32, mul: f32) void {
        if (self.disabled) {
            return;
        }

        var j: usize = 0;
        while (j < samples.len / 1024) : (j += 1) {
            const output = samples[j * 1024 .. j * 1024 + 1024];
            var min = output[0];
            var max = output[0];
            for (output[1..]) |sample| {
                if (sample < min) min = sample;
                if (sample > max) max = sample;
            }

            // TODO maybe just save the samples and let them be processed on the main thread?
            std.mem.copy(f32, self.fft_real, output);
            std.mem.set(f32, self.fft_imag, 0.0);
            fft(1024, self.fft_real, self.fft_imag);

            if (self.full_fft_view) {
                self.draw_spectrum_full.plot(self.fft_real[0..1024], self.logarithmic_fft);
            } else {
                self.draw_waveform.plot(min * mul, max * mul);
                self.draw_spectrum.plot(self.fft_real[0..1024], self.logarithmic_fft);
            }
        }
    }

    // called on the main thread with the audio thread locked
    pub fn blit(self: *Visuals, pixels: []u32, pitch: usize, description: []const u8, recorder_state: @TagType(Recorder.State)) void {
        if (self.full_fft_view and !self.disabled) {
            self.redraw_all = false;
            self.draw_spectrum_full.blit(pixels, pitch);
            return;
        }
        if (self.redraw_all) {
            std.mem.set(u32, pixels, 0);
            drawString(12, 13, pixels, pitch, description);
            self.draw_waveform.reset();
            self.draw_spectrum.reset();
            self.draw_spectrum_full.reset();
            self.draw_recorder_state.reset();
            if (self.disabled) {
                drawString(12, 440, pixels, pitch, "Press F1 to re-enable drawing");
            }
            self.redraw_all = false;
        }
        if (self.disabled) {
            return;
        }
        self.draw_waveform.blit(pixels, pitch);
        self.draw_spectrum.blit(pixels, pitch);
        self.draw_recorder_state.blit(pixels, pitch, recorder_state);
    }
};
