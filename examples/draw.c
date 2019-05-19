#include <math.h>
#include <SDL2/SDL.h>

static const int screen_w = 512;
static const int screen_h = 320;

static float drawbuf[screen_w][2];
static int drawindex;

void plot(float min, float max) {
    drawbuf[drawindex][0] = min;
    drawbuf[drawindex][1] = max;
    if (++drawindex == screen_w) {
        drawindex = 0;
    }
}

static void drawwaveform(unsigned int *pixels, int pitch) {
    const int width = screen_w;
    const int height = 80;
    const int bottom_padding = 8;
    const int y = screen_h - bottom_padding - height;
    const int y_mid = y + height / 2;
    const unsigned int background_color = 0x18181818;
    const unsigned int waveform_color = 0x44444444;
    const unsigned int clipped_color = 0xFFFF0000;
    const unsigned int center_line_color = 0x66666666;

    int i;
    for (i = 0; i < width; i++) {
        float sample_min = drawbuf[i][0];
        float sample_max = drawbuf[i][1];
        float sample_min_clipped = sample_min < -1.0f ? -1.0f : sample_min;
        float sample_max_clipped = sample_max > 1.0f ? 1.0f : sample_max;
        int y0 = (int)(y_mid - sample_max_clipped * height / 2 + 0.5f);
        int y1 = (int)(y_mid - sample_min_clipped * height / 2 + 0.5f);
        int sx = (i - drawindex + width) % width;
        int sy = y;
        if (sample_max_clipped != sample_max)
            pixels[sy++ * pitch + sx] = clipped_color;
        for (; sy < y0; sy++)
            pixels[sy * pitch + sx] = background_color;
        for (; sy < y_mid; sy++)
            pixels[sy * pitch + sx] = waveform_color;
        pixels[sy++ * pitch + sx] = center_line_color;
        for (; sy <= y1; sy++)
            pixels[sy * pitch + sx] = waveform_color;
        for (; sy <= y + height; sy++)
            pixels[sy * pitch + sx] = background_color;
        if (sample_min_clipped != sample_min)
            pixels[--sy * pitch + sx] = clipped_color;
    }
}

static void drawfft(unsigned int *pixels, int pitch, size_t bufsize, const float *values) {
    const int height = 100;
    const int y = screen_h - 8 - 80 - height;
    const unsigned int background_color = 0x00000000;
    const unsigned int color = 0x44444444;
    const float inv_buffer_size = 1.0f / bufsize;

    int i;
    // assume bufsize is a power of two. if it's greater than 1024, halve
    // it until it reaches 1024.
    int step = 0, b = bufsize;
    while (b > 1024) {
        b >>= 1;
        step++;
    }
    // draw only half (so 512 pixels), because the other half is just a mirror
    // image
    for (i = 0; i < (b >> 1); i++) {
        const float v = fabs(values[i << step]) * inv_buffer_size;
        const float v2 = sqrt(v); // sqrt to make things more visible
        const float fv = v2 * (float)height;
        const int value = (int)floor(fv);
        const int value_clipped = value > height - 1 ? height - 1 : value;
        int sy = y;
        for (; sy < y + height - value_clipped; sy++) {
            pixels[sy * pitch + i] = background_color;
        }
        if (sy < y + height) {
            const unsigned int c = 0x44 * (fv - value);
            pixels[sy++ * pitch + i] = 0xFF000000 | (c << 16) | (c << 8) | c;
        }
        for (; sy < y + height; sy++) {
            pixels[sy * pitch + i] = color;
        }
    }
}

static void drawstring(unsigned int *pixels, int pitch, const unsigned char *fontdata, const char *s) {
    const int fontchar_w = 8;
    const int fontchar_h = 13;
    const int start_x = 12;
    const int start_y = 13;
    const unsigned int colour = 0xAAAAAAAA;

    // warning: does no checking for drawing off screen
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
                        pixels[(y + sy) * pitch + x + sx] = colour;
                    }
                }
            }
            x += fontchar_w + 1;
        }
    }
}

void draw(SDL_Window *window, SDL_Surface *screen, const unsigned char *fontdata, const char *s, size_t bufsize, const float *fft) {
    SDL_LockSurface(screen);

    drawwaveform(screen->pixels, screen->pitch >> 2);
    drawfft(screen->pixels, screen->pitch >> 2, bufsize, fft);
    drawstring(screen->pixels, screen->pitch >> 2, fontdata, s);

    SDL_UnlockSurface(screen);
    SDL_UpdateWindowSurface(window);
}
