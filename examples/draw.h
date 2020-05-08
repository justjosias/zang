#ifndef EXAMPLE_DRAW_H
#define EXAMPLE_DRAW_H

#include <SDL2/SDL.h>

void plot(float min, float max, const float *fft, int fft_log);
void draw(SDL_Window *window, SDL_Surface *screen, const unsigned char *fontdata, const char *s, const char *s2, int full_fft);
void clear(SDL_Window *window, SDL_Surface *screen, const unsigned char *fontdata, const char *s);

#endif
