#ifndef EXAMPLE_DRAW_H
#define EXAMPLE_DRAW_H

#include <SDL2/SDL.h>

void plot(float min, float max, const float *fft);
void draw(SDL_Window *window, SDL_Surface *screen, const unsigned char *fontdata, const char *s, int full_fft);
void clear(SDL_Window *window, SDL_Surface *screen, const unsigned char *fontdata, const char *s);

#endif
