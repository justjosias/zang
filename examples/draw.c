#include <math.h>
#include <SDL2/SDL.h>

static const int screen_w = 512;
static const int screen_h = 512;

static const int waveform_height = 81;
static const int bottom_padding = 7;

static float lastfft[512];
static unsigned int fftbuf[screen_w * 512];
static unsigned int waveformbuf[screen_w * waveform_height];
static int drawindex;
static int firstdraw = 1;

/* from stackoverflow */
static float hueToRgb(float p, float q, float t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0f / 6.0f) return p + (q - p) * 6.0f * t;
    if (t < 1.0f / 2.0f) return q;
    if (t < 2.0f / 3.0f) return p + (q - p) * (2.0f / 3.0f - t) * 6;
    return p;
}

static unsigned int hslToRgb(float h, float s, float l) {
    float r, g, b;

    if (s == 0.0f) {
        r = g = b = 1.0f;
    } else {
        float q = l < 0.5f ? l * (1 + s) : l + s - l * s;
        float p = 2 * l - q;
        r = hueToRgb(p, q, h + 1.0f / 3.0f);
        g = hueToRgb(p, q, h);
        b = hueToRgb(p, q, h - 1.0f / 3.0f);
    }

    /* my contribution */
    r *= sqrt(h);
    g *= sqrt(h);
    b *= sqrt(h);

    return 0xFF000000 |
        ((unsigned int)(b * 0xFF) << 16) |
        ((unsigned int)(g * 0xFF) << 8) |
        ((unsigned int)(r * 0xFF));
}

void plot(float sample_min, float sample_max, const float *fft, int fft_log) {
    /* plot waveform */
    {
        const unsigned int background_color = 0x18181818;
        const unsigned int waveform_color = 0x44444444;
        const unsigned int clipped_color = 0xFFFF0000;
        const unsigned int center_line_color = 0x66666666;
        const int y_mid = waveform_height / 2;

        float sample_min_clipped = sample_min < -1.0f ? -1.0f : sample_min;
        float sample_max_clipped = sample_max > 1.0f ? 1.0f : sample_max;
        int y0 = (int)(y_mid - sample_max_clipped * waveform_height / 2 + 0.5f);
        int y1 = (int)(y_mid - sample_min_clipped * waveform_height / 2 + 0.5f);
        int sx = drawindex;
        int sy = 0;

        if (sample_max_clipped != sample_max)
            waveformbuf[sy++ * screen_w + sx] = clipped_color;
        for (; sy < y0; sy++)
            waveformbuf[sy * screen_w + sx] = background_color;
        for (; sy < y_mid; sy++)
            waveformbuf[sy * screen_w + sx] = waveform_color;
        waveformbuf[sy++ * screen_w + sx] = center_line_color;
        for (; sy <= y1 && sy < waveform_height; sy++)
            waveformbuf[sy * screen_w + sx] = waveform_color;
        for (; sy < waveform_height; sy++)
            waveformbuf[sy * screen_w + sx] = background_color;
        if (sample_min_clipped != sample_min)
            waveformbuf[--sy * screen_w + sx] = clipped_color;
    }

    /* plot fft */
    {
        static int prev_fft_log = 0;
        const float inv_buffer_size = 1.0f / 1024.0f;
        int sx = drawindex;
        int i;

        if (prev_fft_log != fft_log) {
            prev_fft_log = fft_log;
            memset(fftbuf, 0, sizeof(fftbuf));
        }

        for (i = 0; i < 512; i++) {
            float v2;

            if (fft_log) {
                const float f = (float)i / 511.0f;

                const float exp = 10.0f;
                const float v = (pow(exp, f) - 1.0f) / (exp - 1.0f);

                const int i0 = (int)floor(v * 511.0f);
                const int i1 = i0 < 512 ? i0 + 1 : i0;
                const float t = v * 511.0f - i0;

                const float v00 = fabs(fft[i0]) * inv_buffer_size;
                const float v01 = fabs(fft[i1]) * inv_buffer_size;

                v2 = v00 * (1.0f - t) + v01 * t;
            } else {
                v2 = fabs(fft[i]) * inv_buffer_size;
            }

            v2 = sqrt(v2); /* kludge to make things more visible */

            fftbuf[(512 - 1 - i) * screen_w + sx] = hslToRgb(v2, 1.0f, 0.5f);
            lastfft[i] = v2;
        }
    }

    if (++drawindex == screen_w) {
        drawindex = 0;
    }
}

static void drawwaveform(unsigned int *pixels, int pitch) {
    const int y = screen_h - bottom_padding - waveform_height;

    int i;
    for (i = 0; i < waveform_height; i++) {
        unsigned int *dest = pixels + (y + i) * pitch;
        const unsigned int *src = waveformbuf + i * screen_w;
        memcpy(dest + (screen_w - drawindex), src, drawindex * sizeof(unsigned int));
        memcpy(dest, src + drawindex, (screen_w - drawindex) * sizeof(unsigned int));
    }
}

static void drawfullfft(unsigned int *pixels, int pitch) {
    int i;
    for (i = 0; i < 512; i++) {
        unsigned int *dest = pixels + i * pitch;
        const unsigned int *src = fftbuf + i * screen_w;
        memcpy(dest + (screen_w - drawindex), src, drawindex * sizeof(unsigned int));
        memcpy(dest, src + drawindex, (screen_w - drawindex) * sizeof(unsigned int));
    }
}

static void drawfft(unsigned int *pixels, int pitch) {
    const int fft_height = 128;
    const int y = screen_h - bottom_padding - waveform_height - fft_height;
    const unsigned int background_color = 0x00000000;
    const unsigned int color = 0x44444444;

    int i;
    for (i = 0; i < 512; i++) {
        const float fv = lastfft[i] * (float)fft_height;
        const int value = (int)floor(fv);
        const int value_clipped = value > fft_height - 1 ? fft_height - 1 : value;
        int sy = y;
        for (; sy < y + fft_height - value_clipped; sy++) {
            pixels[sy * pitch + i] = background_color;
        }
        if (sy < y + fft_height) {
            const unsigned int c = 0x44 * (fv - value);
            pixels[sy++ * pitch + i] = 0xFF000000 | (c << 16) | (c << 8) | c;
        }
        for (; sy < y + fft_height; sy++) {
            pixels[sy * pitch + i] = color;
        }
    }
}

static void drawstring(unsigned int *pixels, int pitch, const unsigned char *fontdata, const char *s) {
    const int fontchar_w = 8;
    const int fontchar_h = 13;
    const int start_x = 12;
    const int start_y = 13;
    const unsigned int color = 0xAAAAAAAA;

    /* warning: does no checking for drawing off screen */
    int x = start_x, y = start_y;
    for (; *s; s++) {
        if (*s == '\n') {
            x = start_x;
            y += fontchar_h + 1;
        } else if (*s >= 32) {
            int index = (*s - 32) * fontchar_h, sx, sy;
            for (sy = 0; sy < fontchar_h; sy++) {
                for (sx = 0; sx < fontchar_w; sx++) {
                    if ((fontdata[index + sy]) & (1 << sx)) {
                        pixels[(y + sy) * pitch + x + sx] = color;
                    }
                }
            }
            x += fontchar_w + 1;
        }
    }
}

void draw(SDL_Window *window, SDL_Surface *screen, const unsigned char *fontdata, const char *s, int full_fft) {
    SDL_LockSurface(screen);

    if (full_fft) {
        drawfullfft(screen->pixels, screen->pitch >> 2);
        firstdraw = 1;
    } else {
        if (firstdraw) {
            memset(screen->pixels, 0, screen_h * screen->pitch);

            /* initialize waveform background and center line */
            memset(waveformbuf, 0x18, sizeof(waveformbuf));
            memset(waveformbuf + (waveform_height / 2) * screen_w, 0x66, screen_w * sizeof(unsigned int));

            firstdraw = 0;
        }

        drawwaveform(screen->pixels, screen->pitch >> 2);
        drawfft(screen->pixels, screen->pitch >> 2);
        drawstring(screen->pixels, screen->pitch >> 2, fontdata, s);
    }

    SDL_UnlockSurface(screen);
    SDL_UpdateWindowSurface(window);
}

void clear(SDL_Window *window, SDL_Surface *screen, const unsigned char *fontdata, const char *s) {
    SDL_LockSurface(screen);

    memset(screen->pixels, 0, screen_h * screen->pitch);
    memset(waveformbuf, 0, screen_w * waveform_height * sizeof(unsigned int));
    drawindex = 0;
    firstdraw = 1;

    drawstring(screen->pixels, screen->pitch >> 2, fontdata, s);

    SDL_UnlockSurface(screen);
    SDL_UpdateWindowSurface(window);
}
