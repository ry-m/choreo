# Choreo

A native music visualiser for macOS. It listens to whatever your Mac is playing, tracks the beat,
bars and song sections in real time, and drives seven raymarched scenes that cut on the downbeat
and react to kicks, snares, vocals and hats separately.

C++20, SDL3 with SDL_GPU on Metal, Core Audio process taps for system audio. Beat tracking uses a
small causal network (trained in PyTorch, run in C++) feeding a bar-pointer HMM.

## Build

Needs macOS 14.2+ (for process taps), CMake 3.24+, Ninja and SDL3 (`brew install sdl3`).

```
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

## Run

```
./build/choreo                       # system audio (asks for System Audio Recording permission)
./build/choreo --app com.spotify.client   # one app only
./build/choreo --mic                 # microphone instead
./build/choreo --fullscreen --fps 120
```

Keys: `1`–`7` pin a scene, `0` hands control back to the director, `F` fullscreen,
`[` / `]` nudge A/V sync by 5 ms, `R` reloads shaders, `Esc` quits.

## Tools

- `choreo-render song.wav` renders offline: `--at 30,60 --sheet` for stills, `--cuts` for a contact
  sheet of every cut, `--bench` for GPU timings per scene.
- `choreo-analyze song.wav` prints beats and tempo.
- `tools/ml/` holds the training code for the beat and section models.

## Scenes

Prism Cathedral, Ember, Laser Nebula, Kaleido Tunnel, Spectral Ridge, Bar Halo and Chrome Tide.
Each one re-rolls its shapes, materials and colours on every cut, so the same scene rarely looks
the same twice.

More detail on the design and results is in [docs/ROADMAP.md](docs/ROADMAP.md).
