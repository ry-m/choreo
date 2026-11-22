#!/usr/bin/env python3
"""Harmonix Set -> Spotify recordings -> aligned beat/downbeat/section labels.

  harmonix.py match RESULTS.json     write tests/reference/harmonix_spotify.csv: songs whose Spotify
                                     version has the same length as the annotated one (same edit)
  harmonix.py align REC_DIR          align each recording to its annotations (small offset search
                                     using the current beat network), reject mismatches, and write
                                     $CHOREO_ML/harmonix_aligned.json for training/evaluation

Only same-length versions are used: Harmonix audio is often a game edit, and a periodic beat grid
alone can't locate an edit. For same-length versions the remaining offset (codec padding, leading
silence) is a few tens of ms, which the network finds unambiguously within +-0.25 s.
"""
import csv, json, os, subprocess, sys
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.environ.get("CHOREO_DATA", os.path.expanduser("~/.cache/choreo/datasets"))
ML = os.environ.get("CHOREO_ML", os.path.expanduser("~/.cache/choreo/ml"))
HX = f"{DATA}/harmonix/harmonixset-main/dataset"
MAX_LEN_DIFF = 5.0  # seconds; small differences are usually fades/endings (checked per window in align)
MAX_HOURS = 10.0    # overnight recording budget
PRIORITY = ["Pop", "Dance", "Electronic", "EDM", "Hip-Hop", "R&B", "Rap", "Disco", "Funk"]


def metadata():
    return {r["File"]: r for r in csv.DictReader(open(f"{HX}/metadata.csv"))}


def annotations(fid):
    beats, downs = [], []
    for line in open(f"{HX}/beats_and_downbeats/{fid}.txt"):
        p = line.split()
        if len(p) >= 2:
            t = float(p[0]); beats.append(t)
            if p[1] == "1":
                downs.append(t)
    segs = []
    sp = f"{HX}/segments/{fid}.txt"
    if os.path.exists(sp):
        for line in open(sp):
            p = line.split(maxsplit=1)
            if len(p) == 2:
                segs.append((float(p[0]), p[1].strip()))
    return beats, downs, segs


def cmd_match(results_path):
    meta = metadata()
    rows = json.load(open(results_path))
    out = os.path.join(ROOT, "tests", "reference", "harmonix_spotify.csv")
    cand = []
    for fid, title, artist, dur, tid, sdur, sname in rows:
        if tid and sdur > 0 and abs(sdur - dur) <= MAX_LEN_DIFF:
            g = meta[fid]["Genre"]
            pri = next((i for i, p in enumerate(PRIORITY) if p.lower() in g.lower()), len(PRIORITY))
            cand.append((pri > len(PRIORITY) - 1, abs(sdur - dur), fid, title, artist, meta[fid]["BPM"], g, tid, sdur))
    cand.sort()
    keep, total = [], 0.0
    for _, _, fid, title, artist, bpm, g, tid, sdur in cand:
        if total + sdur > MAX_HOURS * 3600:
            break
        keep.append((fid, title, artist, bpm, g, tid, sdur))
        total += sdur + 3
    with open(out, "w") as f:
        f.write("# Harmonix Set songs whose Spotify version matches the annotated length (same edit).\n")
        f.write("# 'title' is the Harmonix file id (unique, used as the recording filename).\n")
        f.write("uri,title,artist,bpm,bpm_source\n")
        for fid, title, artist, bpm, genre, tid, dur in keep:
            clean = lambda s: s.replace(",", " ")
            f.write(f"spotify:track:{tid},{fid},{clean(artist)},{bpm},harmonix annotations; {clean(title)}; {genre}; {dur:.0f}s\n")
    print(f"{len(cand)}/{len(rows)} songs within {MAX_LEN_DIFF:.0f} s; queued {len(keep)} (~{total / 3600:.1f} h of recording) -> {out}")


def activation(wav):
    """Beat activation of a recording with the current network (100 fps), via the C++ features."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import torch
    from train_beats import BeatNet, LOOKAHEAD
    tmp = f"{ML}/tmp_align.bin"
    subprocess.run([os.path.join(ROOT, "build", "choreo-features"), wav, tmp], check=True)
    T, D = np.fromfile(tmp, dtype=np.int32, count=2)
    off = float(np.fromfile(tmp, dtype=np.float32, count=1, offset=8)[0])
    x = np.fromfile(tmp, dtype=np.float32, offset=12).reshape(T, D)
    global _model
    if "_model" not in globals():
        _model = BeatNet(); _model.load_state_dict(torch.load(os.path.join(ROOT, "models", "beatnet.bin.pt"), map_location="cpu")); _model.eval()
    with torch.no_grad():
        a = torch.sigmoid(_model(torch.from_numpy(x).unsqueeze(0)))[0].numpy()
    a = np.roll(a, -LOOKAHEAD, axis=0)  # undo the network's look-ahead delay
    return a[:, 0], a[:, 1], off


def offset_scores(a, b, off, dts):
    out = []
    for dt in dts:
        k = np.round((b + dt - off) * 100).astype(int)
        k = k[(k >= 0) & (k < len(a))]
        out.append(float(a[k].mean()) if len(k) else 0.0)
    return np.array(out)


MEL = os.environ.get("CHOREO_HX_MEL", f"{DATA}/harmonix_mel/melspecs")
MEL_HOP = 1024 / 22050          # Harmonix melspec frame period (s)


def slaney_mel_fb(sr=22050, n_fft=2048, n_mels=80, fmax=11025.0):
    """librosa.filters.mel(sr, n_fft, n_mels, fmin=0, fmax, htk=False, norm='slaney')."""
    f_sp, min_log_hz, min_log_mel, logstep = 200 / 3, 1000.0, 15.0, np.log(6.4) / 27
    hz2mel = lambda f: np.where(f < min_log_hz, f / f_sp, min_log_mel + np.log(np.maximum(f, 1e-9) / min_log_hz) / logstep)
    mel2hz = lambda m: np.where(m < min_log_mel, m * f_sp, min_log_hz * np.exp(logstep * (m - min_log_mel)))
    hz = mel2hz(np.linspace(hz2mel(np.array(0.0)), hz2mel(np.array(fmax)), n_mels + 2))
    freqs = np.linspace(0, sr / 2, n_fft // 2 + 1)
    fb = np.zeros((n_mels, len(freqs)))
    for i in range(n_mels):
        lo, c, hi = hz[i], hz[i + 1], hz[i + 2]
        fb[i] = np.maximum(0, np.minimum((freqs - lo) / (c - lo), (hi - freqs) / (hi - c))) * 2 / (hi - lo)
    return fb


def recording_mel(wav):
    """Mel power spectrogram of a recording on the Harmonix melspec grid (44.1 kHz: n_fft 4096, hop
    2048 gives the same 10.8 Hz bins and 46.4 ms frames as 22.05 kHz / 2048 / 1024)."""
    import wave
    w = wave.open(wav)
    sr, n = w.getframerate(), w.getnframes()
    x = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float32) / 32768
    k = round(sr / 22050)
    n_fft, hop = 2048 * k, 1024 * k
    x = np.pad(x, n_fft // 2, mode="reflect")
    frames = np.lib.stride_tricks.sliding_window_view(x, n_fft)[::hop]
    spec = np.abs(np.fft.rfft(frames * np.hanning(n_fft + 1)[:-1], axis=1))[:, :1025] ** 2
    return (spec @ slaney_mel_fb().T).T            # [80, T]


def _norm_logmel(m):
    l = np.log(m + 1e-6)
    l = l - l.mean(1, keepdims=True)
    return l / (l.std(1, keepdims=True) + 1e-6)


def mel_fit(fid, wav):
    """(scale, offset_s, score): recording time = scale * annotation time + offset, from the
    cross-correlation of the recording's log-mel spectrogram with Harmonix's own. Whole-beat
    shifts land on different notes, so unlike a beat-grid fit this has a single clear peak."""
    p = f"{MEL}/{fid}-mel.npy"
    if not os.path.exists(p):
        return None
    A = _norm_logmel(np.load(p))                  # annotated audio
    Bm = _norm_logmel(recording_mel(wav))         # our recording
    best = (1.0, 0.0, -1.0)
    for s in [1.0] + [v for v in np.arange(0.92, 1.0801, 0.0025) if abs(v - 1) > 1e-6]:
        if s != 1.0:
            # resample the annotated spectrogram onto the recording's time axis at this scale
            t = np.arange(int(A.shape[1] * s)) / s
            i0 = np.clip(t.astype(int), 0, A.shape[1] - 2); f = t - i0
            As = A[:, i0] * (1 - f) + A[:, i0 + 1] * f
        else:
            As = A
        L = As.shape[1] + Bm.shape[1]
        n = 1 << int(np.ceil(np.log2(L)))
        c = np.fft.irfft(np.conj(np.fft.rfft(As, n, axis=1)) * np.fft.rfft(Bm, n, axis=1), n, axis=1).sum(0)
        lags = np.r_[np.arange(0, Bm.shape[1]), np.arange(-As.shape[1] + 1, 0)]
        vals = np.r_[c[:Bm.shape[1]], c[n - As.shape[1] + 1:]]
        ok = np.abs(lags) < 15 / MEL_HOP
        k = int(np.argmax(np.where(ok, vals, -np.inf)))
        overlap = min(As.shape[1], Bm.shape[1]) * 80
        score = float(vals[k] / overlap)
        if score > best[2]:
            best = (float(s), float(lags[k] * MEL_HOP), score)
        if s == 1.0 and score > 0.6:
            break                                   # same-speed match found; skip the scale search
    return best


def resolve_bar(a, ad, b, d, off, scale, dt, period):
    """The recording starts a variable few hundred ms into the song (the tap is created after
    Spotify reports playing), so offsets of up to ~1 s are real. A beat grid shifted by whole
    beats fits the beat activation equally well, so pick among
    such shifts by the downbeat activation at the annotated downbeats. Returns (offset,
    downbeats_trusted)."""
    cands = []
    for k in range(-4, 5):
        o = dt + k * period
        sb = offset_scores(a, b * scale, off, [o])[0]
        sd = offset_scores(ad, d * scale, off, [o])[0] if len(d) else 0.0
        cands.append((sd, sb, o))
    best_sb = max(c[1] for c in cands)
    ok = sorted([c for c in cands if c[1] >= 0.85 * best_sb], reverse=True)
    if len(d) and (len(ok) == 1 or ok[0][0] >= 1.5 * ok[1][0]):
        return ok[0][2], True
    # Ambiguous bar position: keep the best beat fit (beat labels are right either way) and
    # mark the downbeats untrusted so training masks them.
    return dt, False


def fit(a, b, off):
    """Best (scale, offset) mapping annotation times onto the recording. First a plain offset
    (same master: codec padding / leading silence, within 1 s); if that's not clear, a time
    scale as well (some Spotify versions are a differently-timed master, e.g. 128 vs 120 BPM)."""
    dts = np.arange(-1.0, 1.0001, 0.005)
    sc = offset_scores(a, b, off, dts)
    if sc.max() >= 0.25 and sc.max() >= 2.0 * np.median(sc):
        return 1.0, float(dts[sc.argmax()]), float(sc.max()), sc
    plain = (1.0, float(dts[sc.argmax()]), float(sc.max()), sc)
    best = (1.0, 0.0, -1.0, sc)
    wide = np.arange(-6.0, 6.0001, 0.01)
    for s in np.arange(0.92, 1.0801, 0.0025):
        ss = offset_scores(a, b * s, off, wide)
        if ss.max() > best[2]:
            best = (float(s), float(wide[ss.argmax()]), float(ss.max()), ss)
    # A scaled fit must be convincing: many scale/offset pairs are tried.
    if best[2] < 0.35 or best[2] < 3.0 * np.median(best[3]):
        return plain                     # judged by the usual (weaker) offset-only threshold
    return best


def cmd_align(rec_dir):
    """Global offset search, then a per-window drift check. A 10 s window is dropped only when
    it *contradicts* the global offset (its own clear best offset is elsewhere, as after an
    edit or a differently-timed master). Windows where the current network is merely unsure
    are kept: those hard passages are what the new training data is for."""
    meta, out, rejected = metadata(), [], []
    dts = np.arange(-0.25, 0.2501, 0.005)   # local (per-window) drift search
    for wav in sorted(os.listdir(rec_dir)):
        fid = wav[:-4]
        if not wav.endswith(".wav") or fid not in meta:
            continue
        beats, downs, segs = annotations(fid)
        a, ad, off = activation(os.path.join(rec_dir, wav))
        b0 = np.array(beats)
        mf = mel_fit(fid, os.path.join(rec_dir, wav))
        if mf and mf[2] >= 0.35:
            # Spectrogram match: absolute offset to one frame (46 ms); refine on the beat activation.
            scale, coarse, melS = mf
            # The spectrogram rules out whole-beat shifts, so the beat fit may search up to 40% of a beat.
            w = min(0.2, 0.4 * float(np.median(np.diff(b0))) * scale)
            fine = np.arange(-w, w + 1e-9, 0.005)
            sc = offset_scores(a, b0 * scale, off, coarse + fine)
            best, bestS, down_ok = float(coarse + fine[sc.argmax()]), float(sc.max()), True
            # Clock drift: recordings can run ~0.1% fast or slow (playback vs device clock), which
            # walks the grid off the beats over a few minutes. Fit a line through per-window offsets.
            for _ in range(2):
                ts, ds, ws = [], [], []
                for w0 in np.arange(0, len(a) / 100 - 5, 10.0):
                    bw = b0 * scale + best; bw = bw[(bw >= w0) & (bw < w0 + 10)]
                    if len(bw) < 4: continue
                    ls = offset_scores(a, bw, off, dts)
                    if ls.max() >= 0.3 and ls.max() >= 1.6 * np.median(ls):
                        ts.append(w0 + 5); ds.append(dts[ls.argmax()]); ws.append(ls.max())
                if len(ts) < 4: break
                ts, ds, ws = map(np.array, (ts, ds, ws))
                keep = np.ones(len(ts), bool)
                for _ in range(3):
                    c1, c0 = np.polyfit(ts[keep], ds[keep], 1, w=ws[keep])
                    keep = np.abs(ds - (c0 + c1 * ts)) < 0.04
                    if keep.sum() < 4: break
                if keep.sum() < 4 or abs(c1) > 0.01: break
                best, scale = best + c0 - c1 * best, scale * (1 + c1)   # t' = t + c0 + c1*t
            if bestS < 0.1:
                rejected.append((fid, f"mel match {melS:.2f} but beats don't fit ({bestS:.2f})"))
                continue
        else:
            scale, best, bestS, sc = fit(a, b0, off)
            if bestS < 0.2 or bestS < 1.8 * np.median(sc):
                rejected.append((fid, f"no clear offset {bestS:.2f} (mel {mf[2] if mf else 'n/a'})"))
                continue
            best, down_ok = resolve_bar(a, ad, b0, np.array(downs), off, scale, best,
                                        float(np.median(np.diff(b0))) * scale)
        tf = lambda t, s=scale, o=best: t * s + o   # annotation time -> recording time
        b = tf(b0)
        best = 0.0                               # b is already in recording time below
        good, bad = [], 0
        end = min(len(a) / 100, b[-1] + best + 0.5)      # labels only up to the last annotated beat
        for w0 in np.arange(max(0.0, b[0] + best - 0.5), end, 10.0):
            w1 = min(w0 + 10, end)
            bw = b[(b + best >= w0) & (b + best < w1)]
            if len(bw) < 4:
                continue
            ls = offset_scores(a, bw, off, dts)
            lbest = float(dts[ls.argmax()])
            clear = ls.max() >= 0.25 and ls.max() >= 1.6 * np.median(ls)
            if clear and abs(lbest - best) > 0.03:
                bad += 1
                continue
            good.append([float(w0), float(w1)])
        if sum(e - s for s, e in good) < 30 or bad > 0.3 * (len(good) + bad):
            rejected.append((fid, f"drift ({bad} contradicting windows)"))
            continue
        merged = []
        for s0, e0 in good:
            if merged and abs(merged[-1][1] - s0) < 1e-6:
                merged[-1][1] = e0
            else:
                merged.append([s0, e0])
        out.append(dict(name=fid, wav=os.path.join(rec_dir, wav), offset=float(tf(0.0)), scale=float(scale),
                        score=bestS, spans=merged, dropped=bad, downbeats_ok=down_ok, mel=mf[2] if mf else None, beats=[float(tf(t)) for t in beats],
                        downbeats=[float(tf(t)) for t in downs], segments=[(float(tf(t)), l) for t, l in segs],
                        genre=meta[fid]["Genre"]))
    os.makedirs(ML, exist_ok=True)
    json.dump(out, open(f"{ML}/harmonix_aligned.json", "w"))
    hours = sum(e - s for d in out for s, e in d["spans"]) / 3600
    print(f"aligned {len(out)} ({hours:.1f} h labelled), rejected {len(rejected)}:")
    for r in rejected:
        print("  ", *r)
    print(f"time-scaled fits: {[(d['name'], round(d['scale'], 4)) for d in out if d['scale'] != 1.0]}")
    print(f"downbeats trusted for {sum(d['downbeats_ok'] for d in out)}/{len(out)} songs")
    offs = [d["offset"] for d in out]
    print(f"offsets: median {1000 * np.median(offs):+.0f} ms, range {1000 * min(offs):+.0f}..{1000 * max(offs):+.0f} ms; "
          f"windows dropped for drift: {sum(d['dropped'] for d in out)}")


if __name__ == "__main__":
    {"match": cmd_match, "align": cmd_align}[sys.argv[1]](sys.argv[2])
