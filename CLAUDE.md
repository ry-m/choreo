# Choreo

Native C++ music visualiser (macOS first): SDL3 + SDL_GPU (Metal), system-audio capture via Core
Audio process taps, real-time beat/tempo analysis with a learned causal beat network. Full design,
milestone history and all past results: `docs/ROADMAP.md` (read the relevant section, not all of it).

## Build & test
```
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build
./build/test_analysis                                   # analyser unit tests
./build/test_beatnet models/beatnet.bin models/beatnet_testvec.bin   # C++ == PyTorch inference
```
Python (training/eval only): `.venv/bin/python` (torch, numpy, MPS). Shaders are MSL compiled at runtime.

## Layout
- `src/analysis/` — `BarTracker` (HMM bar-pointer filter: tempo/phase/bar from the network; default),
  `Analyzer` (onsets, pulse clarity / beat presence, song-change resets, old ACF+PLL tracker behind
  `CHOREO_TRACKER=old`; many `CHOREO_*` env tuning hooks, e.g. `CHOREO_BT*`), `Features` (mel features, shared with training), `BeatNet`
  (streaming TCN inference), `MusicState.h` (what visuals consume).
- `src/audio/` — capture (system / per-app tap / mic), clock pairs for A/V sync.
- `src/app/`, `src/render/`, `shaders/` — app, renderer, visuals.
- `tools/` — `choreo-analyze` (offline WAV → beats/tempo), `choreo-live-eval` (plays Spotify,
  captures silently, scores; `--record` saves WAVs), `choreo-features`, eval scripts.
- `tools/ml/` — `build_dataset.py` → `train_beats.py` → `models/beatnet.bin`; `harmonix.py` (align
  Spotify recordings to Harmonix annotations); `split.json` (train/val/test, committed).

## Evaluation (use these; don't hand-tune by ear)
- Beat F/CMLt/AMLt on held-out clips: `SPLIT=test .venv/bin/python tools/eval_beats.py all`
  (gtzan, ballroom, harmonix; also downbeat F). Current (bar tracker + net v3): 0.856 / 0.915 / 0.948,
  downbeat 0.574 / 0.781 / 0.835. Tune on `SPLIT=val`, report `SPLIT=test`.
- Tempo on Spotify recordings: `tools/eval_offline.py "ENV=..."` (80 songs, `~/.cache/choreo/rec`,
  refs in `tests/reference/spotify*.csv`; 81.0% exact, 94.9% half/double; also Black Ops 2 and unit
  tests); song changes: `tools/eval_transitions.py`. Web BPM refs often double half-time songs.
- Harmonix tempo: 158 recordings in `~/.cache/choreo/harmonix_rec`, refs `tests/reference/harmonix_spotify.csv`
  (expert annotations; 81.1% exact, 93.3% half/double).
- Override the model with `CHOREO_MODEL=path` (`none` disables). Report before/after tables.
- Section changes: `.venv/bin/python tools/ml/sections.py train` (787 Harmonix songs from melspecs),
  `... sections.py eval test` (27 recorded songs, Choreo features + live tracker, ±1 beat).

## Data (never commit audio, features or datasets)
`~/.cache/choreo/`: `datasets/{gtzan,ballroom,harmonix}`, `rec/` (Spotify set), `harmonix_rec/`,
`ml/` (features, `harmonix_aligned.json`, older model backups), `datasets/harmonix_mel/melspecs`
(official Harmonix spectrograms of all 912 songs: exact alignment of recordings, section training).

## Rules
- Ask before downloading anything new; ask before showing a demo (user is often on Remote Control).
- Spotify playback must stay silent unless told otherwise (muted per-app tap; `--audible` to hear).
- Long jobs (training ~20 min, overnight recording) run in the background with a log.
