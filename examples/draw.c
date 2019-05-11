#include <SDL2/SDL.h>

static float drawbuf[640][2];
static int drawindex;

void plot(float min, float max) {
    drawbuf[drawindex][0] = min;
    drawbuf[drawindex][1] = max;
    if (++drawindex == 640) {
        drawindex = 0;
    }
}

static void drawwaveform(unsigned int *pixels, int pitch) {
    const int width = 640;
    const int height = 80;
    const int bottom_padding = 10;
    const int y = 480 - bottom_padding - height;
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

static void drawstring(unsigned int *pixels, int pitch, const char *s) {
    static const char *font =
        "0000000044444040::000000::O:O::04N5>D?403C842IH02552E9F084200000"
        "84222480248884204E>4>E40044O440000000442000O00000000066000@84210"
        ">AIECA>0465444O0>A@@<3O0>A@<@A>0<:999O80O1?@@A>0>1?AAA>0OA@88440"
        ">AA>AA>0>AAAN@>000400400004004428421248000O0O000248@8420>AA84040"
        ">A@FEE>0>AAAOAA0?BB>BB?0>A111A>0?BBBBB?0O11O11O0O11O1110>A11IAN0"
        "AAAOAAA0>44444>0L8888960A95359A0111111O0AKKEEEA0ACCEIIA0>AAAAA>0"
        "?AAA?110>AAAE9F0?AAA?9A0>A1>@A>0O4444440AAAAAA>0AA:::440AAEEE::0"
        "AA:4:AA0AA:44440O@8421O0>22222>0001248@0>88888>04:A00000000000O0"
        "2480000000>@NA^011=CAA?000>A1A>0@@FIAAN000>AO1>0<22O222000^AAN@>"
        "11=CAAA04064444080<8888622B:6:B0644444<000?EEEE000?AAAA000>AAA>0"
        "00>AA?1100>AAN@@00=C111000N1>@?022O222<0009999F000AA::4000AEE::0"
        "00A:4:A000AA::4300O842O0H44244H04444444034484430002E800000000000";

    const int ix = 8;
    const int iy = 8;
    const unsigned int colour = 0x88888888;

    // warning: does no checking for drawing off screen
    int x = ix, y = iy;
    for (; *s; s++) {
        if (*s == '\n') {
            x = ix; y += 20;
        } else if (*s >= 32) {
            int index = (*s - 32) << 3, sx, sy;
            for (sy = 0; sy < 16; sy++) {
                for (sx = 0; sx < 16; sx++) {
                    if ((font[index + (sy >> 1)] - '0') & (1 << (sx >> 1))) {
                        pixels[(y + sy) * pitch + x + sx] = colour;
                    }
                }
            }
            x += 16;
        }
    }
}

void draw(SDL_Window *window, SDL_Surface *screen, const char *s) {
    SDL_LockSurface(screen);

    drawwaveform(screen->pixels, screen->pitch >> 2);
    drawstring(screen->pixels, screen->pitch >> 2, s);

    SDL_UnlockSurface(screen);
    SDL_UpdateWindowSurface(window);
}
