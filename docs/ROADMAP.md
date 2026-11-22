# Choreo — Vision, Architecture & Roadmap

## Vision
A native, high-performance music visualiser whose visuals are *choreographed* to the music:
it knows where the beat, the bar, the build-up and the drop are, and the 3D scenes respond
with intent — not just "bass makes things wobble". Geared to modern music (EDM, pop,
hip-hop) where tempo is stable, kicks are strong and structure (build → drop → breakdown) matters.

## Goals
1. **Accurate musical understanding** in real time: onsets, tempo, beat phase, downbeats/bars,
   per-instrument hits (kick / snare / hats), energy, and sections (build-up, drop, breakdown).
2. **Low latency**: under 30 ms from sound to photon after latency compensation (beats are *predicted*, not just detected).
3. **System audio capture** (what's playing on the computer), with the microphone as a fallback.
4. **High-quality, diverse 3D visuals**: raymarched/SDF scenes, fractals, particles, volumetrics,
   feedback and post effects; many scenes with smooth, beat-synced transitions.
5. **Built from scratch**: our own DSP, analysis and render code. Only platform layers are
   third-party (SDL3 for windowing/GPU abstraction, OS audio APIs).
6. **Measurable quality**: beat tracking scored against annotated datasets (F-measure,
   CMLt/AMLt), with regression tests so the algorithm only gets better.

## Tech stack
| Layer | Choice | Why |
|---|---|---|
| Language | C++20 (+ Objective-C++ on macOS) | Performance, direct OS access |
| Window / input / GPU | SDL3 + SDL_GPU | One API over Metal / Vulkan / D3D12, compute shaders, no deprecated GL |
| Shaders | MSL now → HLSL/Slang cross-compiled later (M4) | Command Line Tools only: compiled at runtime from source for now |
| macOS capture | Core Audio **process taps** (macOS 14.2+) | Real system audio, no virtual driver like BlackHole needed |
| Windows capture | WASAPI loopback | Built-in |
| Linux capture | PipeWire / PulseAudio monitor source | Built-in |
| Fallback | SDL3 recording device (mic / line-in) | Works everywhere |
| Build | CMake + Ninja | Cross-platform |

## Architecture
```
 ┌────────────── audio thread ──────────────┐     ┌──── analysis thread* ────┐     ┌──── render thread ────┐
 │ Capture backend (tap / WASAPI / mic)     │ ──▶ │ FFT → bands → onset flux │ ──▶ │ Scene director        │
 │  → mono mix → lock-free SPSC ring buffer │     │ tempo → beat PLL → bars  │     │ Scenes (SDF, particles)│
 └──────────────────────────────────────────┘     │ energy → sections        │     │ Post FX, transitions  │
                                                  └─ MusicState (atomic) ────┘     └───────────────────────┘
```
*For now, analysis runs on the render thread draining the ring buffer (it costs well under 1 ms per frame). It moves to its own thread in M2.

The central contract is **`MusicState`**: a plain struct published every analysis hop (~10 ms)
that visuals read. Visuals never touch raw audio. That keeps scenes simple and lets the
analysis be tested offline.

```
src/
  audio/      capture backends, ring buffer
  analysis/   FFT, band filterbank, onset detection, tempo, beat tracker, MusicState
  render/     SDL_GPU renderer, shaders, scenes
  app/        main loop, UI/hotkeys
tools/
  choreo-analyze   offline: WAV in → beats/onsets/BPM out (for evaluation)
tests/        DSP unit tests + synthetic beat-tracking tests
```

## The analysis algorithm (target design)
1. **Front end**: 48 kHz mono, 2048-sample Hann window, 512 hop (~94 frames/s).
   Log-magnitude spectrum is pooled into ~40 log-spaced bands.
2. **Onset detection function (ODF)**: half-wave-rectified log spectral flux per band, also
   grouped into **kick (30–150 Hz), snare/body (150 Hz–2.5 kHz) and hats (5 kHz+)** streams.
   Peak picking uses an adaptive threshold (moving mean/median plus an offset, and a minimum gap).
3. **Tempo**: autocorrelation of the ODF over a ~6 s window, plus harmonic enhancement
   (energy at the lag, 2× the lag and 4× the lag), weighted by a log-Gaussian prior around 120–128 BPM
   to settle octave errors. Tracked over time with hysteresis so the BPM doesn't jitter.
4. **Beat phase**: comb-template phase search over recent ODF history, then a phase-locked
   loop (PLL) that nudges the running phase. This gives a **predicted** next beat, so visuals can hit exactly on time.
5. **Downbeats / bars** (M2): kick-and-bass accent pattern plus harmonic-change detection over
   4-beat groupings.
6. **Sections** (M3): short-term/long-term energy ratio, spectral-centroid slope and
   hi-hat/riser density detect **build-ups**. A **drop** is a sudden low-band energy return after a
   build or breakdown. Self-similarity novelty finds section boundaries.
7. **Learned model** (M5, optional): a small CRNN that outputs beat/downbeat activations, trained
   offline and run in our own inference code. It replaces stage 2's ODF when it scores better.

## Roadmap
### M0 — Foundation ✅ (this commit)
- CMake project, SDL3 window, SDL_GPU (Metal) fullscreen raymarched shader
- macOS system-audio capture via process tap, with SDL mic fallback
- Lock-free ring buffer, custom FFT, first-pass analyser (bands, onsets, tempo, beat phase)
- `choreo-analyze` offline tool and a synthetic beat-tracking test

### M1 — Beat accuracy (in progress)
Done:
- ✅ `choreo-analyze` reads MP3/M4A directly, with `--timeline` and `--ref-bpm`;
  `tools/eval_tempo.sh` scores every track in `tests/reference/tempos.csv` (audio is looked up in
  `$CHOREO_MUSIC_DIR`, default `~/Desktop`)
- ✅ Pulse clarity and `beatPresent` (hysteresis 0.30 on / 0.20 off). Beats don't fire while absent.
  A fresh lock discards evidence from before the beat arrived.
- ✅ Metrical lock: after an 8 s probation, related tempos (2:1, 3:2, 4:3...) are held as the same
  pulse. An unrelated tempo must win by 15% for 3 s.
- ✅ Locally detrended ODF (no false beats from swells/risers). Fixed the ACF normalisation bug.
- ✅ Tempo prior centred at 128 BPM (σ = 0.5 octave)
- Tuning hooks for experiments: `CHOREO_HW`, `CHOREO_PRIOR`, `CHOREO_PRESENCE` env vars

Results: Black Ops 2 is correct 100% of the time while a beat is present (was ~45%). Roll with Me is 100%.
These are only 2 real tracks, so the prior choice may be overfit. More references are needed.

- ✅ Live evaluation through Spotify (`choreo-live-eval`, muted per-app tap, `--record` for an
  offline cache, `tools/eval_progress.sh` progress view). Reference sets are in `tests/reference/spotify*.csv`,
  and results are in `tests/results/`.
- ✅ Song-change handling: silence reset, valid-history ACF, recency weighting (τ = 5 s), and a related-tempo
  hold that only applies while the held level is still supported (≥60% of the best score)
- ✅ Half-beat (subdivision) evidence in the tempo score: fixes 2:3 / 3:4 impostors (DnB 174 → 116)

Live results (30-track broad set, exact tempo while a beat is present):
baseline 59.8% (8 tracks never locked, median lock 10.6 s) → run 2 **84.6%** (1 never locked, median 5.8 s).

Run 3 (offline, on 80 live recordings of real songs; 40 of them held out from tuning):
- Acc1 (exact tempo) **87.1%**, Acc2 (exact or half/double) **93.3%**. Median time to the correct tempo is 3.9 s,
  and only 1 track never locks. On the held-out 40 alone: Acc1 87.1%, Acc2 91.3%, so it generalises.
- Hard cut between songs (30 joined pairs, no gap): median 3.7 s to re-lock (was 8.3 s), thanks to
  the timbre-novelty song-change detector (soft reset keeps the beat, drops old rhythm history).
- Changes: novelty soft reset (threshold 1.5), related-level switch needs 4 s, warm-up 1.5 s,
  one-bar (4x) harmonic weight 0.5. Opus is excluded because its intro genuinely accelerates (~129 → 183).
- Tried and rejected (no gain or worse): ODF kick/snare/hat weighting, two-bar (8x) evidence,
  a separate kick/bass-band tempo vote.
- Offline tools: `tools/eval_offline.py` and `tools/eval_transitions.py` (set `CHOREO_REC_DIR` to the
  `--record` cache). Each one runs in seconds, against an hour for a live run.
- Remaining: 4:3 errors from dotted hooks (Starboy 124 for 93; Lean On's intro), Strobe's beatless arp
  intro (88), and slow locks caused by long beatless intros. Further gains likely need a learned onset/beat
  activation (M5), not more heuristics.

A/V sync (latency compensation):
- Capture publishes (sample index ↔ host time) pairs. The output device's latency is read from Core Audio.
  Each frame shows `Analyzer::stateAt(heard time)`: earlier moments replay the exact recorded state
  (Bluetooth), later moments predict the beat forward (speakers).
- `--calibrate`: Choreo plays a 120 BPM click, hears it through system capture and flashes on each beat.
  `[` / `]` shift the visuals 5 ms (saved in the app-data folder).
- `--tap`: tap SPACE on the beat. Every 8 taps it reports whether Choreo is early or late, and by how much, and how many taps were
  off-beat. This is the ground truth for phase, because kick-onset references are contaminated by bass lines.
- Synthetic phase accuracy: beats are 5 ms early, with a 1.5 ms spread. On real music, the nearest kick sits a median of 8 ms
  from the predicted beat. Some songs (Gosh, Starboy, Shake It Off, Closer) may lock half a beat out; to be confirmed by tapping.

Beat-phase ground truth (no human tapping): GTZAN (999 clips, 10 genres) and Ballroom (698), with expert
beat annotations, in `~/.cache/choreo/datasets` (not in the repo). Run `tools/eval_beats.py all`, ~12 s.
SMC was skipped: its host is offline, and the only copy found contains spectrograms, not audio.
- Baseline: GTZAN F 0.701 / AMLt 0.722, Ballroom F 0.672 / AMLt 0.640.
- With a BTrack-style cumulative beat score for phase (+ snare weight in the phase ODF): **GTZAN F 0.730 /
  AMLt 0.756, Ballroom F 0.702 / AMLt 0.698**. By genre: disco 0.93, reggae 0.85, hip-hop 0.82,
  pop/rock ~0.75. Classical and jazz are weak, as expected.
- Tried and rejected: kick-weighted phase (bass lines pull it off-beat), loudness/bass-accent phase flipping,
  and PLL gain changes.
- Remaining: about 14% off-beat beats (76 GTZAN clips mostly off-beat), mostly a wrong choice when the lock
  first forms. Classic signal features don't separate on/off-beat reliably; this is the strongest case
  for a learned beat/downbeat activation, trained on these annotations.

Learned beat/downbeat detector (v1), PyTorch for training only; inference is our own C++:
- `MelFeatures` (64 log-mel + 64 positive-difference, 100 fps, any sample rate) is shared by training
  export (`choreo-features`) and runtime. Causal TCN: 11 dilated residual blocks (receptive field ~20 s),
  48 channels, 121k params, 20 ms look-ahead, beat + downbeat outputs. Trained on GTZAN + Ballroom
  (1,436 clips x 5 speeds, ±9 dB gain); 261 clips held out (`tools/ml/split.json`).
- `tools/ml/build_dataset.py` → `tools/ml/train_beats.py` (~20 min on M5 MPS) → `models/beatnet.bin`.
  `test_beatnet` checks that the C++ streaming inference matches PyTorch (max error 1.4e-6).
- Held-out clips, full tracker: **GTZAN F 0.721 → 0.814, Ballroom F 0.697 → 0.831**, mostly-off-beat clips
  21 → 10, median beat offset −15 → −1 ms. Peak-picking the activation alone gives F 0.864.
- Spotify set: half/double accuracy 93.3% → 94.1% and lock time 3.8 → 3.3 s, but exact tempo 87.0% → 83.5%.
  DnB now locks at half tempo (87), and drumless modern intros (We Found Love, Bloom) read 4:3 until the drums
  enter. The training data has little modern EDM/pop and no DnB. **Next: modern training data** (Harmonix
  via silent Spotify recording + annotation alignment), and bar/downbeat tracking from the downbeat output.
- Note: the checkpoint was selected on the held-out split, so those numbers are slightly optimistic. Next
  time, use a separate validation split.

**Harmonix data (v2 model).** 158 Harmonix Set songs recorded silently from Spotify overnight (~10 h,
`tools/ml/record_harmonix.sh`). `tools/ml/harmonix.py align` maps annotations onto each recording (offset
within ±1 s, or offset + time scale for differently-timed masters such as Dynamite at 128 vs 120 BPM) and
drops 10 s windows that clearly contradict the fit: 129 songs, 7.4 h of verified beat labels. Splits are now
train / val / test; the model is picked on val (`tools/ml/split.json`).
- **Downbeats aren't usable yet**: the recording starts a variable 0–1 s into the song, so a beat grid shifted
  by whole beats fits equally well. Only 3/129 bar positions were unambiguous; Harmonix downbeats are masked in
  training. `choreo-live-eval --record` now saves Spotify's start position next to each WAV, so future
  recordings can be placed in absolute time.
- Results (held-out; full tracker F / network peak-pick F):

  | | GTZAN | Ballroom | Harmonix (26) |
  |---|---|---|---|
  | v1 full tracker | 0.814 | 0.831 | 0.936 |
  | v2 full tracker | 0.813 | 0.832 | 0.939 |
  | v1 network only | 0.841 | 0.903 | 0.917 |
  | v2 network only | 0.843 | 0.902 | 0.926 |

  Tempo, exact / half-double: Harmonix 158 songs 75.8/94.2% → 76.0/94.3%; Spotify set 83.5/94.1% → 84.3/94.9%.
  (The Harmonix test set is biased toward songs v1 already handles: alignment uses v1's activation.)
- **Finding: the network is no longer the bottleneck, the tracker is.** Peak-picking the activation beats the
  full tracker by 3–7 points of F. Next: rework the tempo/phase stage on top of the activation (e.g. a
  causal bar-pointer / particle filter over tempo × phase × bar position, using the downbeat output too).

**Bar-pointer tracker** (`src/analysis/BarTracker.{h,cpp}`, default when a model is loaded;
`CHOREO_TRACKER=old` for the previous path). Online HMM filtering over meter (3/4, 4/4) x beat in bar x
beat period (60–200 BPM) x position, ~32k states, on the network's beat + downbeat activations at 100 fps.
Tempo changes only at beat boundaries (stiffness λ=100). Output: most likely state, projected to the hop
time; beat presence still comes from pulse clarity. New `MusicState` fields: `beatInBar`, `beatsPerBar`,
`barPhase`, `downbeat`, `barConfidence`. Design choices, all measured (tuned on the val split):
- Fixed ±3-frame beat region at every tempo, centred on the beat. madmom's τ/16 region favoured slow
  tempos with our few-frame-wide peaks (tango at 62 instead of 130) and placed beats ~20 ms early.
- Non-beat likelihood (1 − act)/7; downbeat weight 0.5; observation temperature 0.5 (a hypothesis
  survives a weak beat).
- Miss floor 0.05 on the beat-region likelihood: an unheard beat in a half-time section costs little, so
  the metrical level holds (Black Ops 2 49% → 88% exact, Animals 43% → 100%). 0.1+ drifts to double tempo.
- Tried and dropped: output smoothing / hysteresis (worse at every setting), a per-beat tempo prior
  (no effect), continuity-only level hold (locks the intro's level), folding into a preferred range
  (`CHOREO_LEVEL`, off: trades annotated-level accuracy for web-BPM conventions), loudness-weighted level
  votes (intros out-vote drops).

  | Held-out test | GTZAN F | Ballroom F | Harmonix F | GTZAN dbF | Ballroom dbF |
  |---|---|---|---|---|---|
  | Old tracker | 0.813 | 0.832 | 0.939 | – | – |
  | Network peak-pick | 0.843 | 0.902 | 0.926 | 0.53 | 0.63 |
  | **Bar tracker** | **0.857** | **0.905** | 0.939 | **0.565** | **0.756** |

  Tempo exact / half-double: Harmonix 158 songs 76.0/94.3% → **81.1/93.3%** (expert annotations); Spotify
  set 84.3/94.9% → 81.0/94.9% (web BPMs, which often double half-time hip-hop/EDM); Black Ops 2 100 → 88%.
  Song change (30 joined pairs): re-lock 4.6 → 3.6 s median. CPU ≈ 0.25% of a core.
- Next: downbeats from Harmonix (re-record with start positions, then train the downbeat output on them);
  the visuals can now use bars (`barPhase`, `downbeat`).

Known failures (run 2): Opus (arpeggio intro, 3:2), Hey Ya! and GoGo! (4:3), and an Innerbloom regression
(7 flips on a slow-building deep house intro). Lock time is still ~10 s on some tracks.

Remaining:
- Get annotated test sets (GTZAN-beats, Ballroom, plus a hand-labelled EDM/pop set)
- `choreo-eval`: F-measure (±70 ms), CMLt and AMLt, a tempo octave-error rate; runs in CI
- **Beat presence**: a "pulse clarity" measure that tells beatless sections (ambient intros,
  breakdowns) apart from rhythmic ones. While there's no pulse, stop firing beats and switch
  the visuals to energy/spectrum-driven motion. When the beat arrives, discard the intro's
  estimate and lock fast. (The current `tempoConfidence` reads ~0.84 during Black Ops 2's
  beatless intro, so it measures peak shape, not whether a beat exists.)
- **Metrical continuity**: once locked, treat tempos in simple ratios to the current one (2:1, 3:2)
  as the *same* pulse at another level and don't switch to them. Black Ops 2 flips between
  96 and 144 BPM at section changes, even after the intro.
- Tune the ODF, tempo prior and PLL gains; measure and compensate output latency
- Targets: F ≥ 0.85 on EDM/pop, lock in ≤ 3 s, no phase drift over 5 minutes

### M2 — Musical structure
- Downbeat and bar detection, a 4/8/16-bar phrase counter
- Analysis on its own thread, with a triple-buffered MusicState
- Debug overlay: ODF plot, tempo curve, beat ticks (essential for tuning)

### M3 — Sections & dynamics
**Core product principle (the main gap in existing visualisers): visuals blend continuously
within a section, but when the music changes significantly (a drop, a chorus, a breakdown) the
visuals change *on the beat*.** Hard cuts and scene switches are quantised to the downbeat where the new
section starts (from `BarTracker`), never mid-bar, and never delayed until the next bar.
- Section-change detector: causal, scored against Harmonix segment labels (intro/verse/chorus/drop...),
  reporting "a new section starts at this downbeat" plus its kind and intensity (drop vs subtle change).
  It has to fire on the downbeat itself, so it needs anticipation (builds, risers, snare rolls, filter
  sweeps, the silence before a drop). Evaluated by hit rate at ±1 beat, false cuts per minute and latency.
- **Status (section detector v0, `tools/ml/sections.py`, PyTorch only so far).**
  - Exact Harmonix alignment: our recordings are matched to the official Harmonix mel spectrograms
    (`harmonix.py` `mel_fit`, plus a clock-drift line fit: recordings run up to ~0.1% fast/slow). The
    beat-grid-only alignment had most songs out by whole beats (86/123 moved, many by 3–5 s); downbeat labels
    now verified (network downbeat activation on labelled downbeats ×2.7 vs ×1.06). 143/158 songs, 8.5 h,
    139 with downbeats. This also gave beat network v3 (Harmonix downbeats in training): Harmonix downbeat
    F 0.741 → 0.835, Ballroom 0.756 → 0.781, beat F equal or better.
  - Model: causal GRU per beat on beat-synchronous 16-band envelopes (relative to a running average),
    bar position, tempo and repetition distances (vs 1/2/4/8 bars back). Heads: *next* (a section starts
    on the next beat: decided at the downbeat) and *conf* (it started on this beat: 1 beat late), each for
    any boundary and for lifts (into a chorus/drop, or +0.5 level jump). Cuts fire only on downbeats.
  - Trained on 787 Harmonix songs straight from the melspecs (envelopes are source-independent: ~0.9
    per-band correlation with Choreo's own features on the same audio); tested on 27 unseen recorded songs
    through Choreo's features and live tracker (±1 beat):

    | head | P | R | F | false cuts/min |
    |---|---|---|---|---|
    | next, any | 0.31 | 0.41 | 0.35 | 2.3 |
    | next, lift | 0.19 | 0.28 | 0.23 | 1.3 |
    | conf, any | 0.48 | 0.49 | 0.49 | 1.3 |
    | conf, lift | 0.30 | 0.36 | 0.33 | 1.0 |

  - Not yet good enough for hard cuts. Next: measure what look-ahead buys (heads 2/4/8 beats late), a
    richer model (bar-level attention over the last 16 bars), cleaner lift labels, then the C++ port.
- Masking live-audio latency (combine all three):
  1. **Predict**: the beat grid already says when the next downbeat is; an anticipation score from the
     build (risers, snare rolls, filter sweeps, bass removal, pre-drop silence) commits the cut to it.
  2. **Hide a late detection under the hit**: an unannounced change still has a kick/onset on its downbeat,
     detected within ~20 ms. Fire a big flash/white-out on the hit and swap the scene underneath it a few
     frames later once confirmed; a false alarm costs only a flash, not a wrong cut.
  3. **Look-ahead mode** (optional, per-app capture): capture the app muted at the source (as
     `choreo-live-eval` does) and play it back from Choreo delayed by ~0.3–0.5 s. The analyser hears the
     future, so drops, choruses and downbeats are known before the listener hears them. Costs a short lag
     on play/skip. Plain system-audio capture stays real-time and relies on 1 and 2.
- Build-up / drop / breakdown detection, plus riser/snare-roll detection
- "Anticipation" signals: progress through a build (0→1) and time to the predicted drop

### M4 — Visual engine
- Shader toolchain (Slang or HLSL → SPIR-V/MSL/DXIL), hot reload
- Render graph: HDR targets, bloom, chromatic aberration, feedback/trails, film grain, tonemapping
- GPU compute particles (1M+), SDF scene library, volumetric fog
- Scene director: continuous blending and intensity within a section; on a detected section change, a
  hard switch (new scene, palette, camera) exactly on that downbeat; smaller accents on phrase boundaries
- 8–12 distinct scenes (fractal tunnels, kaleidoscopic Mandelbox, liquid chrome, particle galaxies, neon grids)

### M5 — Polish & intelligence
- Optional learned beat/downbeat model
- Per-genre presets, user-tunable reactivity, a palette system
- App bundle, permission flow, settings UI, multi-monitor fullscreen

### M6 — Cross-platform
- Windows (WASAPI loopback, D3D12/Vulkan) and Linux (PipeWire, Vulkan)
- Later: mobile

## Running (macOS)
```
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/choreo            # system audio (asks for "System Audio Recording" permission)
./build/choreo --mic      # microphone fallback
./build/choreo --fps 120  # frame cap (default 60); resolution adapts to hold it
./build/choreo --fullscreen
./build/choreo-analyze song.wav
```
Keys: `F` fullscreen, `Esc` quit.
