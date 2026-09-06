TECHNICAL
=========

Purpose
-------
This document explains how the Ada Plasma MP3 Player works: audio decoding, spectrum analysis, music-reactive plasma generation, rendering, controls, and deterministic MP4 export. It includes the main formulas and short Ada/C snippets illustrating key APIs.

Overview & Architecture
-----------------------
- Ada application (src/plasma_player.adb) orchestrates UI, analysis, visualization, and control flow.
- Small C bridge (c/player_bridge.c) handles SDL2 initialization, window and surface updates, and libmpg123 audio decoding integration.
- ffmpeg is used for offline MP4 export by piping raw BGRA frames to ffmpeg's stdin and muxing original MP3 audio.

Design goals
------------
- Single-track playback (keep UI simple and keyboard-driven).
- Fast, deterministic rendering for recording/export.
- Software rendering first: update an SDL surface with BGRA pixels. Avoid GPU context quirks.
- Simple C-bridge to reuse mature C libraries (SDL2, libmpg123) and keep Ada code readable.

Audio decoding
--------------
- libmpg123 decodes MP3 to 44.1 kHz stereo signed 16-bit PCM.
- The bridge fills a lock-free circular buffer of PCM samples for analysis and also queues audio to SDL audio callback for playback.
- Ada reads recent PCM history (default ~6s) for spectrum analysis and smoothing.

Spectrum analysis
-----------------
- The player splits audio into N = 48 logarithmically spaced bands between ~40 Hz and ~12 kHz.
- A Goertzel-like band-energy estimator is used per-band in a short rolling window to reduce compute vs. full FFT. This is well suited for a fixed set of center frequencies.

Band center frequencies
- For band i in 0..N-1, map logarithmically:

  f_i = f_low * (f_high / f_low)^(i / (N-1))

  where f_low ≈ 40 Hz, f_high ≈ 12000 Hz.

Goertzel-style magnitude (short description)
- For each band, compute a single complex bin magnitude over the analysis buffer length L (samples). Using the Goertzel recurrence avoids a full FFT when only a fixed set of frequencies is needed.

  s[n] = x[n] + 2*cos(ω)*s[n-1] - s[n-2]

  ω = 2π * f_i / Fs

  magnitude ≈ sqrt(s1^2 + s2^2 - 2*cos(ω)*s1*s2)

- Implementation detail: apply a Hann window to samples to reduce spectral leakage and accumulate magnitude squared, then sqrt. Use small L (e.g., 2048 samples) and compute bands incrementally over the rolling buffer.

Smoothing & aggregation
-----------------------
- Each band energy is smoothed using an exponential moving average (alpha_smooth ≈ 0.25 for visual stability).
- Bass, Mid, Treble aggregates compute auto-switch energy:

  Energy = Bass*1.45 + Mid + Treble*0.85

- Auto-switch uses energy flux and a cooldown (default 900 ms) to change plasma patterns automatically when energy spikes.

Spectrum bars mapping
---------------------
- Bars visualize the smoothed band magnitudes. Taller bars = stronger recent energy.
- Bands are grouped or drawn directly across the horizontal span, left->right mapping low->high frequencies.
- Bar color is a vertical gradient derived from the current palette; left->right base hue sweep is applied so low bands are warmer/darker, highs are brighter/cooler.

Plasma generation math
----------------------
Plasma is a procedurally generated 2D field where pixel color is a function of position (x,y) and time t. A common formula used in the player is a combination of sine fields:

  p(x,y,t) = sin(a1*x + b1*y + c1*t + phase1) \
           + sin(a2*x + b2*y + c2*t + phase2) \
           + sin(sqrt((x+ox)^2 + (y+oy)^2) * r + c3*t)

- Coefficients (a1..c3), offsets (ox, oy), and radius factor r are driven by audio aggregates (bass/mid/treble) to make the plasma react to music.
- The value p(x,y,t) is normalized to [0,1] and used as an index into a palette or to compute HSV hue/saturation/value.

Example palette mapping (pseudo-code):

  idx = (p * palette_size) mod palette_size
  color = palette[idx]

Or using HSV sweep:

  hue = base_hue + p * hue_range
  rgb = HSVtoRGB(hue, saturation, value)

Color strobe & auto-switch
--------------------------
- Strobe mode simply increments the current palette index at a fixed rapid rate while enabled (toggle S). It preserves pattern but cycles colors.
- Auto-switch mode monitors Energy and switches pattern/palette when thresholds are crossed, respecting cooldown.

Rendering pipeline
------------------
- Each frame: sample current time, read the latest smoothed band energies, compute plasma pixel values for each pixel (or a scaled grid for performance and upsample if needed), draw spectrum bars if enabled, draw overlays (intro cards, animated text), and blit BGRA pixel buffer to SDL window surface.
- To avoid GLX/SDL framebuffer acceleration issues, the C bridge sets:

  SDL_SetHint(SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");

  and uses SDL_UpdateWindowSurface() after writing to the surface->pixels memory.

- Frame rate is capped (e.g., 60 Hz) to remain deterministic and reduce CPU usage.

Intro overlay & text
--------------------
- Intro overlay (--intro-overlay) displays the track title (derived from filename by stripping .mp3 extension) and an optional author line (--name).
- Text uses a custom 5x7 bitmap font and per-letter sine-wave vertical offset for animation (same style as About popup).
- Background is drawn transparent (overlay composited over plasma) and fades out after a configurable duration (default 5s).

Small Ada/C snippets
--------------------
Ada spec for bridge functions (src/c_bridge.ads):

  package C_Bridge is
     procedure Init_SDL(Width, Height : Integer);
     procedure Present_Frame(Pixels : System.Address); -- BGRA buffer
     -- audio callbacks and event polling omitted for brevity
  end C_Bridge;

C usage (bridge) example (c/player_bridge.c):

  SDL_SetHint(SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
  SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO);
  window = SDL_CreateWindow(...);
  surface = SDL_GetWindowSurface(window);
  /* write BGRA pixels into surface->pixels */
  SDL_UpdateWindowSurface(window);

MP4 recording & deterministic export
-----------------------------------
- Recording mode (--record) renders frames offline deterministically: the decoder runs in a mode that provides decoded PCM in exactly the same order but avoids audio playback jitter. Frames are computed at fixed timestamps.
- The program opens a pipe to ffmpeg with a command like:

  ffmpeg -y -f rawvideo -pixel_format bgra -video_size WxH -framerate 60 -i - \
         -i input.mp3 -c:v libx264 -preset veryfast -crf 18 -c:a copy output.mp4

- Raw BGRA frames are written to ffmpeg stdin as the player renders them. Audio is provided by the original MP3 file (copied) to ensure perfect A/V sync.
- Determinism considerations: use fixed RNG seed for any random startup choices, fixed framerate, and fixed plasma math constants; avoid system-timed randomness.

Build & Run
-----------
Requirements: GNAT (gnatmake/gprbuild), SDL2 development headers, libmpg123-dev, ffmpeg for recording.

Build (top-level Makefile):

  make

Or with gprbuild directly:

  gprbuild -P mp3player.gpr

Run (play t.mp3):

  ./bin/mp3player t.mp3

Run with options:

  ./bin/mp3player --window-size 960x540 --intro-overlay --name="Ulrik Hørlyk Hjort" t.mp3

Record MP4 (deterministic):

  ./bin/mp3player --record output.mp4 --window-size 960x540 t.mp3

Tuning parameters
-----------------
- Bands N (default 48) - more bands increase detail at the cost of CPU.
- Rolling history length (seconds) - longer history smooths the analyzer response.
- Smoothing alpha for bands - increase for smoother visuals, decrease for more reactive visuals.
- Auto-switch cooldown - default 900 ms.

Known limitations and future work
---------------------------------
- Font supports limited glyph set; full Unicode rendering is not implemented. Names are normalized to ASCII-like characters where necessary.
- Performance: software pixel loops are CPU-bound for large windows. Consider rendering to a lower-resolution buffer and upscaling, or using an SDL texture with hardware acceleration where driver quirks allow.
- Expand band analysis to FFT + mel/log bin mapping for better frequency resolution and optimization.



Appendix: Useful constants & formulas
------------------------------------
- Logarithmic band mapping: f_i = f_low * (f_high / f_low)^(i/(N-1))
- Hann window: w[n] = 0.5 * (1 - cos(2πn/(L-1)))
- Goertzel recurrence: s[n] = x[n] + 2*cos(ω)s[n-1] - s[n-2]


