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
- `src/analysis/` — `Analyzer` (ODF, tempo ACF, metrical lock, phase/PLL, cumulative beat score;
  many `CHOREO_*` env tuning hooks), `Features` (mel features, shared with training), `BeatNet`
  (streaming TCN inference), `MusicState.h` (what visuals consume).
- `src/audio/` — capture (system / per-app tap / mic), clock pairs for A/V sync.
- `src/app/`, `src/render/`, `shaders/` — app, renderer, visuals.
- `tools/` — `choreo-analyze` (offline WAV → beats/tempo), `choreo-live-eval` (plays Spotify,
  captures silently, scores; `--record` saves WAVs), `choreo-features`, eval scripts.
- `tools/ml/` — `build_dataset.py` → `train_beats.py` → `models/beatnet.bin`; `harmonix.py` (align
  Spotify recordings to Harmonix annotations); `split.json` (train/val/test, committed).

## Evaluation (use these; don't hand-tune by ear)
- Beat F/CMLt/AMLt on held-out clips: `SPLIT=test .venv/bin/python tools/eval_beats.py all`
  (gtzan, ballroom, harmonix). Current: full tracker 0.813 / 0.832 / 0.939; network peak-pick
  0.843 / 0.902 / 0.926 — the tracker, not the network, is the gap.
- Tempo on Spotify recordings: `tools/eval_offline.py "ENV=..."` (80 songs, `~/.cache/choreo/rec`,
  refs in `tests/reference/spotify*.csv`); song changes: `tools/eval_transitions.py`.
- Harmonix tempo: 158 recordings in `~/.cache/choreo/harmonix_rec`, refs `tests/reference/harmonix_spotify.csv`.
- Override the model with `CHOREO_MODEL=path` (`none` disables). Report before/after tables.

## Data (never commit audio, features or datasets)
`~/.cache/choreo/`: `datasets/{gtzan,ballroom,harmonix}`, `rec/` (Spotify set), `harmonix_rec/`,
`ml/` (features, `harmonix_aligned.json`, v1 model backup). Harmonix downbeats are masked in training
(bar position ambiguous in old recordings); new `--record` runs save Spotify's start position.

## Rules
- Ask before downloading anything new; ask before showing a demo (user is often on Remote Control).
- Spotify playback must stay silent unless told otherwise (muted per-app tap; `--audible` to hear).
- Long jobs (training ~20 min, overnight recording) run in the background with a log.
