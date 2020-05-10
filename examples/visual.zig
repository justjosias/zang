const std = @import("std");

const fontdata = @embedFile("font.dat");

pub const screen_w = 512;
pub const screen_h = 512;

const waveform_height = 81;
const bottom_padding = 7;

pub fn drawString(start_x: usize, start_y: usize, pixels: []u32, pitch: usize, s: []const u8) void {
    const fontchar_w = 8;
    const fontchar_h = 13;
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

pub const DrawSpectrum = struct {
    lastfft: [512]f32,
    fftbuf: [screen_w * 512]u32,
    logarithmic: bool,
    drawindex: usize,

    pub fn init(self: *DrawSpectrum) void {
        self.logarithmic = false;
        self.drawindex = 0;
    }

    pub fn plot(self: *DrawSpectrum, in_fft: *[1024]f32, logarithmic: bool) void {
        const inv_buffer_size = 1.0 / 1024.0;
        var sx = self.drawindex;

        if (self.logarithmic != logarithmic) {
            self.logarithmic = logarithmic;
            std.mem.set(u32, &self.fftbuf, 0);
        }

        var i: usize = 0;
        while (i < 512) : (i += 1) {
            var v2: f32 = undefined;

            if (logarithmic) {
                const f = @intToFloat(f32, i) / 511.0;

                const exp = 10.0;
                const v = (std.math.pow(f32, exp, f) - 1.0) / (exp - 1.0);

                const v0 = @floatToInt(usize, std.math.floor(v * 511.0));
                const v1 = if (v0 < 512) v0 + 1 else v0;
                const t = v * 511.0 - @intToFloat(f32, v0);

                const v00 = std.math.fabs(in_fft[v0]) * inv_buffer_size;
                const v01 = std.math.fabs(in_fft[v1]) * inv_buffer_size;

                v2 = v00 * (1.0 - t) + v01 * t;
            } else {
                v2 = std.math.fabs(in_fft[i]) * inv_buffer_size;
            }

            v2 = std.math.sqrt(v2); // kludge to make things more visible

            self.fftbuf[(512 - 1 - i) * screen_w + sx] = hslToRgb(v2, 1.0, 0.5);
            self.lastfft[i] = v2;
        }

        self.drawindex += 1;
        if (self.drawindex == screen_w) {
            self.drawindex = 0;
        }
    }

    pub fn blitSmall(self: *DrawSpectrum, pixels: []u32, pitch: usize) void {
        const fft_height = 128;
        const y: usize = screen_h - bottom_padding - waveform_height - fft_height;
        const background_color: u32 = 0x00000000;
        const color: u32 = 0x44444444;

        var i: usize = 0;
        while (i < 512) : (i += 1) {
            const fv = self.lastfft[i] * @intToFloat(f32, fft_height);
            const value = @floatToInt(u32, std.math.floor(fv));
            const value_clipped = std.math.min(value, fft_height - 1);
            var sy = y;
            while (sy < y + fft_height - value_clipped) : (sy += 1) {
                pixels[sy * pitch + i] = background_color;
            }
            if (sy < y + fft_height) {
                const co: u32 = 0x44 * (@floatToInt(u32, fv) - value);
                pixels[sy * pitch + i] = @as(u32, 0xFF000000) | (co << 16) | (co << 8) | co;
                sy += 1;
            }
            while (sy < y + fft_height) : (sy += 1) {
                pixels[sy * pitch + i] = color;
            }
        }
    }

    pub fn blitFull(self: *DrawSpectrum, pixels: []u32, pitch: usize) void {
        var i: usize = 0;
        while (i < 512) : (i += 1) {
            const dest_start = i * pitch;
            const dest = pixels[dest_start .. dest_start + screen_w];

            const src_start = i * screen_w;
            const src = self.fftbuf[src_start .. src_start + screen_w];

            std.mem.copy(u32, dest[screen_w - self.drawindex ..], src[0..self.drawindex]);
            std.mem.copy(u32, dest[0 .. screen_w - self.drawindex], src[self.drawindex..]);
        }
    }
};

pub const DrawWaveform = struct {
    waveformbuf: [screen_w * waveform_height]u32,
    drawindex: usize,

    const background_color: u32 = 0x18181818;
    const waveform_color: u32 = 0x44444444;
    const clipped_color: u32 = 0xFFFF0000;
    const center_line_color: u32 = 0x66666666;
    const y_mid = waveform_height / 2;

    pub fn init(self: *DrawWaveform) void {
        std.mem.set(u32, &self.waveformbuf, background_color);

        const start = waveform_height / 2 * screen_w;
        const end = start + screen_w;
        std.mem.set(u32, self.waveformbuf[start..end], center_line_color);

        self.drawindex = 0;
    }

    pub fn plot(self: *DrawWaveform, sample_min: f32, sample_max: f32) void {
        const sample_min_clipped = std.math.max(-1.0, sample_min);
        const sample_max_clipped = std.math.min(1.0, sample_max);
        var y0 = @floatToInt(usize, y_mid - sample_max * @intToFloat(f32, waveform_height / 2) + 0.5);
        var y1 = @floatToInt(usize, y_mid - sample_min * @intToFloat(f32, waveform_height / 2) + 0.5);
        var sx = self.drawindex;
        var sy: usize = 0;
        var until: usize = undefined;

        if (sample_max >= 1.0) {
            self.waveformbuf[sy * screen_w + sx] = clipped_color;
            sy += 1;
        }
        until = std.math.min(y0, y_mid);
        while (sy < until) : (sy += 1) {
            self.waveformbuf[sy * screen_w + sx] = background_color;
        }
        until = std.math.min(y1, y_mid);
        while (sy < until) : (sy += 1) {
            self.waveformbuf[sy * screen_w + sx] = waveform_color;
        }
        while (sy < y_mid) : (sy += 1) {
            self.waveformbuf[sy * screen_w + sx] = background_color;
        }
        self.waveformbuf[sy * screen_w + sx] = center_line_color;
        sy += 1;
        if (y0 > y_mid) {
            until = std.math.min(y0, waveform_height);
            while (sy < until) : (sy += 1) {
                self.waveformbuf[sy * screen_w + sx] = background_color;
            }
        }
        until = std.math.min(y1, waveform_height);
        while (sy < until) : (sy += 1) {
            self.waveformbuf[sy * screen_w + sx] = waveform_color;
        }
        while (sy < waveform_height) : (sy += 1) {
            self.waveformbuf[sy * screen_w + sx] = background_color;
        }
        if (sample_min <= -1.0) {
            sy -= 1;
            self.waveformbuf[sy * screen_w + sx] = background_color;
        }

        self.drawindex += 1;
        if (self.drawindex == screen_w) {
            self.drawindex = 0;
        }
    }

    pub fn blit(self: *DrawWaveform, pixels: []u32, pitch: usize) void {
        const y = screen_h - bottom_padding - waveform_height;

        var i: usize = 0;
        while (i < waveform_height) : (i += 1) {
            const dest_start = (y + i) * pitch;
            const dest = pixels[dest_start .. dest_start + screen_w];

            const src_start = i * screen_w;
            const src = self.waveformbuf[src_start .. src_start + screen_w];

            std.mem.copy(u32, dest[screen_w - self.drawindex ..], src[0..self.drawindex]);
            std.mem.copy(u32, dest[0 .. screen_w - self.drawindex], src[self.drawindex..]);
        }
    }
};
