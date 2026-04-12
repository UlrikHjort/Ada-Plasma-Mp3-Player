/***************************************************************************
--                Plasma Player - player bridge
--
--           Copyright (C) 2026 By Ulrik Hørlyk Hjort
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
-- LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
-- OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- ***************************************************************************/
#define _POSIX_C_SOURCE 200809L

#include <SDL2/SDL.h>
#include <mpg123.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static SDL_Window *g_window = NULL;
static SDL_Surface *g_window_surface = NULL;
static SDL_Window *g_about_window = NULL;
static SDL_Surface *g_about_surface = NULL;
static SDL_AudioDeviceID g_audio_device = 0;
static mpg123_handle *g_mpg = NULL;
static int g_mpg123_ready = 0;
static char g_last_error[256];
static Uint32 g_window_id = 0;
static Uint32 g_about_window_id = 0;

int player_bridge_prepare_decoder(void);
static int open_mp3_common(const char *path, int open_audio);
static void close_about_window(void);

static void bridge_set_error(const char *fmt, ...) {
    va_list args;

    va_start(args, fmt);
    vsnprintf(g_last_error, sizeof(g_last_error), fmt, args);
    va_end(args);
}

const char *player_bridge_last_error(void) {
    if (g_last_error[0] == '\0') {
        return NULL;
    }

    return g_last_error;
}

int player_bridge_init(const char *title, int width, int height) {
    g_last_error[0] = '\0';

    /* Force the old framebuffer path here: some X11 setups crash on GLX setup
       even when we do not intend to use accelerated rendering. */
    SDL_SetHint(SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_EVENTS) != 0) {
        bridge_set_error("SDL_Init: %s", SDL_GetError());
        return -1;
    }

    g_window = SDL_CreateWindow(
        title,
        SDL_WINDOWPOS_CENTERED,
        SDL_WINDOWPOS_CENTERED,
        width,
        height,
        SDL_WINDOW_SHOWN);
    if (g_window == NULL) {
        bridge_set_error("SDL_CreateWindow: %s", SDL_GetError());
        return -1;
    }
    g_window_id = SDL_GetWindowID(g_window);

    /* The player presents frames by copying into the window surface directly,
       which keeps SDL away from renderer/OpenGL backend selection. */
    g_window_surface = SDL_GetWindowSurface(g_window);
    if (g_window_surface == NULL) {
        bridge_set_error("SDL_GetWindowSurface: %s", SDL_GetError());
        return -1;
    }

    if (player_bridge_prepare_decoder() != 0) {
        return -1;
    }

    return 0;
}

int player_bridge_prepare_decoder(void) {
    g_last_error[0] = '\0';

    if (!g_mpg123_ready) {
        if (mpg123_init() != MPG123_OK) {
            bridge_set_error("mpg123_init failed");
            return -1;
        }
        g_mpg123_ready = 1;
    }

    return 0;
}

static void close_audio_device(void) {
    if (g_audio_device != 0) {
        SDL_CloseAudioDevice(g_audio_device);
        g_audio_device = 0;
    }
}

static void close_mpg(void) {
    if (g_mpg != NULL) {
        mpg123_close(g_mpg);
        mpg123_delete(g_mpg);
        g_mpg = NULL;
    }
}

void player_bridge_shutdown(void) {
    close_audio_device();
    close_mpg();
    close_about_window();

    if (g_mpg123_ready) {
        mpg123_exit();
        g_mpg123_ready = 0;
    }

    g_window_surface = NULL;
    if (g_window != NULL) {
        SDL_DestroyWindow(g_window);
        g_window = NULL;
    }
    g_window_id = 0;

    SDL_Quit();
}

static int open_mp3_common(const char *path, int open_audio) {
    int error = MPG123_OK;
    long rate = 0;
    int channels = 0;
    int encoding = 0;
    SDL_AudioSpec want;
    SDL_AudioSpec have;

    g_last_error[0] = '\0';
    close_audio_device();
    close_mpg();

    if (player_bridge_prepare_decoder() != 0) {
        return -1;
    }

    g_mpg = mpg123_new(NULL, &error);
    if (g_mpg == NULL) {
        bridge_set_error("mpg123_new: %s", mpg123_plain_strerror(error));
        return -1;
    }

    if (mpg123_param(g_mpg, MPG123_ADD_FLAGS, MPG123_QUIET, 0.0) != MPG123_OK) {
        bridge_set_error("mpg123_param failed");
        return -1;
    }

    if (mpg123_format_none(g_mpg) != MPG123_OK) {
        bridge_set_error("mpg123_format_none failed");
        return -1;
    }

    if (mpg123_format(g_mpg, 44100, MPG123_STEREO, MPG123_ENC_SIGNED_16) != MPG123_OK) {
        bridge_set_error("mpg123_format failed");
        return -1;
    }

    if (mpg123_open(g_mpg, path) != MPG123_OK) {
        bridge_set_error("mpg123_open: %s", mpg123_strerror(g_mpg));
        return -1;
    }

    if (mpg123_getformat(g_mpg, &rate, &channels, &encoding) != MPG123_OK) {
        bridge_set_error("mpg123_getformat: %s", mpg123_strerror(g_mpg));
        return -1;
    }

    if (rate != 44100 || channels != 2 || encoding != MPG123_ENC_SIGNED_16) {
        bridge_set_error("unexpected decoded format");
        return -1;
    }

    if (open_audio) {
        SDL_zero(want);
        SDL_zero(have);
        want.freq = (int)rate;
        want.format = AUDIO_S16SYS;
        want.channels = (Uint8)channels;
        want.samples = 4096;

        g_audio_device = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
        if (g_audio_device == 0) {
            bridge_set_error("SDL_OpenAudioDevice: %s", SDL_GetError());
            return -1;
        }

        if (have.format != AUDIO_S16SYS || have.channels != 2 || have.freq != 44100) {
            bridge_set_error("unexpected SDL audio format");
            return -1;
        }

        SDL_PauseAudioDevice(g_audio_device, 0);
    }

    return 0;
}

static void close_about_window(void) {
    g_about_surface = NULL;
    if (g_about_window != NULL) {
        SDL_DestroyWindow(g_about_window);
        g_about_window = NULL;
    }
    g_about_window_id = 0;
}

int player_bridge_open_mp3(const char *path) {
    return open_mp3_common(path, 1);
}

int player_bridge_open_mp3_silent(const char *path) {
    return open_mp3_common(path, 0);
}

int player_bridge_decode_chunk(void *buffer, int capacity) {
    size_t done = 0;
    int status;

    if (g_mpg == NULL) {
        bridge_set_error("decoder not open");
        return -1;
    }

    status = mpg123_read(g_mpg, buffer, (size_t)capacity, &done);
    if (status == MPG123_DONE) {
        return 0;
    }
    if (status != MPG123_OK) {
        bridge_set_error("mpg123_read: %s", mpg123_strerror(g_mpg));
        return -1;
    }

    return (int)done;
}

int player_bridge_queue_audio(const void *buffer, unsigned length) {
    if (g_audio_device == 0) {
        bridge_set_error("audio device not open");
        return -1;
    }

    if (SDL_QueueAudio(g_audio_device, buffer, (Uint32)length) != 0) {
        bridge_set_error("SDL_QueueAudio: %s", SDL_GetError());
        return -1;
    }

    return 0;
}

unsigned player_bridge_get_queued_audio_size(void) {
    if (g_audio_device == 0) {
        return 0;
    }

    return (unsigned)SDL_GetQueuedAudioSize(g_audio_device);
}

void player_bridge_clear_audio(void) {
    if (g_audio_device != 0) {
        SDL_ClearQueuedAudio(g_audio_device);
    }
}

void player_bridge_pause_audio(int paused) {
    if (g_audio_device != 0) {
        SDL_PauseAudioDevice(g_audio_device, paused ? 1 : 0);
    }
}

void player_bridge_rewind_mp3(void) {
    if (g_mpg != NULL) {
        mpg123_seek(g_mpg, 0, SEEK_SET);
    }
}

long long player_bridge_track_length_frames(void) {
    off_t length;

    if (g_mpg == NULL) {
        bridge_set_error("decoder not open");
        return -1;
    }

    length = mpg123_length(g_mpg);
    if (length < 0) {
        if (mpg123_scan(g_mpg) != MPG123_OK) {
            bridge_set_error("mpg123_scan: %s", mpg123_strerror(g_mpg));
            return -1;
        }
        length = mpg123_length(g_mpg);
    }

    return (long long)length;
}

int player_bridge_poll_event(void) {
    SDL_Event event;
    int mask = 0;

    while (SDL_PollEvent(&event)) {
        if (event.type == SDL_QUIT) {
            mask |= 1;
        } else if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_CLOSE) {
            if (event.window.windowID == g_window_id) {
                mask |= 1;
            } else if (event.window.windowID == g_about_window_id) {
                close_about_window();
                mask |= 256;
            }
        } else if (event.type == SDL_MOUSEBUTTONDOWN && event.button.windowID == g_window_id) {
            mask |= 128;
        } else if (event.type == SDL_KEYDOWN) {
            switch (event.key.keysym.sym) {
                case SDLK_ESCAPE:
                    mask |= 1;
                    break;
                case SDLK_SPACE:
                    mask |= 2;
                    break;
                case SDLK_r:
                    mask |= 4;
                    break;
                case SDLK_a:
                    mask |= 8;
                    break;
                case SDLK_p:
                    mask |= 16;
                    break;
                case SDLK_c:
                    mask |= 32;
                    break;
                case SDLK_m:
                    mask |= 64;
                    break;
                case SDLK_s:
                    mask |= 512;
                    break;
                default:
                    break;
            }
        }
    }

    return mask;
}

void player_bridge_set_window_title(const char *title) {
    if (g_window != NULL) {
        SDL_SetWindowTitle(g_window, title);
    }
}

int player_bridge_open_about_window(const char *title, int width, int height) {
    close_about_window();

    g_about_window = SDL_CreateWindow(
        title,
        SDL_WINDOWPOS_CENTERED,
        SDL_WINDOWPOS_CENTERED,
        width,
        height,
        SDL_WINDOW_SHOWN);
    if (g_about_window == NULL) {
        bridge_set_error("SDL_CreateWindow(about): %s", SDL_GetError());
        return -1;
    }

    g_about_window_id = SDL_GetWindowID(g_about_window);
    g_about_surface = SDL_GetWindowSurface(g_about_window);
    if (g_about_surface == NULL) {
        bridge_set_error("SDL_GetWindowSurface(about): %s", SDL_GetError());
        close_about_window();
        return -1;
    }

    return 0;
}

void player_bridge_close_about_window(void) {
    close_about_window();
}

int player_bridge_present_about_rgba(const void *pixels, int pitch) {
    if (g_about_window == NULL || g_about_surface == NULL) {
        bridge_set_error("about window surface not initialized");
        return -1;
    }

    if (SDL_MUSTLOCK(g_about_surface) && SDL_LockSurface(g_about_surface) != 0) {
        bridge_set_error("SDL_LockSurface(about): %s", SDL_GetError());
        return -1;
    }

    if (SDL_ConvertPixels(
            g_about_surface->w,
            g_about_surface->h,
            SDL_PIXELFORMAT_ARGB8888,
            pixels,
            pitch,
            g_about_surface->format->format,
            g_about_surface->pixels,
            g_about_surface->pitch) != 0) {
        if (SDL_MUSTLOCK(g_about_surface)) {
            SDL_UnlockSurface(g_about_surface);
        }
        bridge_set_error("SDL_ConvertPixels(about): %s", SDL_GetError());
        return -1;
    }

    if (SDL_MUSTLOCK(g_about_surface)) {
        SDL_UnlockSurface(g_about_surface);
    }

    if (SDL_UpdateWindowSurface(g_about_window) != 0) {
        bridge_set_error("SDL_UpdateWindowSurface(about): %s", SDL_GetError());
        return -1;
    }

    return 0;
}

int player_bridge_present_rgba(const void *pixels, int pitch) {
    if (g_window == NULL || g_window_surface == NULL) {
        bridge_set_error("window surface not initialized");
        return -1;
    }

    if (SDL_MUSTLOCK(g_window_surface) && SDL_LockSurface(g_window_surface) != 0) {
        bridge_set_error("SDL_LockSurface: %s", SDL_GetError());
        return -1;
    }

    /* Convert from our fixed ARGB8888 frame buffer into the native window
       surface format each frame. */
    if (SDL_ConvertPixels(
            g_window_surface->w,
            g_window_surface->h,
            SDL_PIXELFORMAT_ARGB8888,
            pixels,
            pitch,
            g_window_surface->format->format,
            g_window_surface->pixels,
            g_window_surface->pitch) != 0) {
        if (SDL_MUSTLOCK(g_window_surface)) {
            SDL_UnlockSurface(g_window_surface);
        }
        bridge_set_error("SDL_ConvertPixels: %s", SDL_GetError());
        return -1;
    }

    if (SDL_MUSTLOCK(g_window_surface)) {
        SDL_UnlockSurface(g_window_surface);
    }

    if (SDL_UpdateWindowSurface(g_window) != 0) {
        bridge_set_error("SDL_UpdateWindowSurface: %s", SDL_GetError());
        return -1;
    }

    return 0;
}

unsigned player_bridge_ticks(void) {
    return SDL_GetTicks();
}

void player_bridge_delay(unsigned milliseconds) {
    SDL_Delay((Uint32)milliseconds);
}

void *player_bridge_pipe_open_write(const char *command) {
    /* MP4 export streams raw frames to ffmpeg over a pipe instead of writing
       temporary image files. */
    FILE *pipe = popen(command, "w");
    if (pipe == NULL) {
        bridge_set_error("popen failed");
        return NULL;
    }

    return pipe;
}

size_t player_bridge_pipe_write(void *handle, const void *buffer, size_t length) {
    FILE *pipe = (FILE *)handle;

    if (pipe == NULL) {
        bridge_set_error("pipe not open");
        return 0;
    }

    return fwrite(buffer, 1, length, pipe);
}

int player_bridge_pipe_close(void *handle) {
    FILE *pipe = (FILE *)handle;

    if (pipe == NULL) {
        bridge_set_error("pipe not open");
        return -1;
    }

    return pclose(pipe);
}
