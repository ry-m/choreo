#!/usr/bin/env python3
"""Section-change detector: does a new section (chorus, drop, verse...) start on the next beat?

A small causal GRU that runs once per beat on beat-synchronous summaries of Choreo's mel features.
Two outputs per beat i (decided when beat i has been heard, i.e. at the start of beat i+1):
  next  P(beat i+1 starts a new section)  -> lets visuals cut exactly on that downbeat (prediction)
  conf  P(beat i started a new section)   -> one beat later; a late cut hidden under the hit

  sections.py train [--epochs N]     train on Harmonix train songs (annotated beats), pick on val
  sections.py eval [val|test]        score with the *live tracker's* beats (choreo-analyze), +-1 beat

Labels: Harmonix segment starts mapped to the nearest annotated beat ($CHOREO_ML/harmonix_aligned.json).
Model: models/sections.pt (PyTorch; the C++ port comes once the approach is proven).
"""
import argparse, json, os, random, subprocess, sys
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ML = os.environ.get("CHOREO_ML", os.path.expanduser("~/.cache/choreo/ml"))
ALIGNED = os.environ.get("CHOREO_SECTIONS_LABELS", f"{ML}/harmonix_aligned.json")
FPS = 100
BANDS = 16
EMA_BEATS = 32
D_BASE = 2 * BANDS + 2
REP_BARS = (1, 2, 4, 8)
D_IN = D_BASE + 4 + 1 + len(REP_BARS) + 1  # EMA-relative levels, bar position, tempo, repetition
LIFT_SCALE = 1.0
LIFT_DELTA = 0.5           # level jump (log band energy, 8 s after vs before) that counts as a lift
N_OUT = 4                   # next_any, next_lift, conf_any, conf_lift
REFRACTORY = 8              # beats between fired cuts
SKIP_LABELS = {"end", "silence"}


HX = os.environ.get("CHOREO_DATA", os.path.expanduser("~/.cache/choreo/datasets")) + "/harmonix"
MELDIR = f"{HX[:-9]}/harmonix_mel/melspecs"
ENV_FPS = 22050 / 1024        # common envelope frame rate (Harmonix melspec grid)
EDGES = np.geomspace(80, 11000, BANDS + 1)


def _group(centres):
    return np.clip(np.searchsorted(EDGES, centres) - 1, 0, BANDS - 1)


def _slaney_centres(n=80, fmax=11025.0):
    f_sp, mlh, mlm, ls = 200 / 3, 1000.0, 15.0, np.log(6.4) / 27
    hz2mel = lambda f: f / f_sp if f < mlh else mlm + np.log(f / mlh) / ls
    mel2hz = lambda m: m * f_sp if m < mlm else mlh * np.exp(ls * (m - mlm))
    pts = np.linspace(hz2mel(0.0), hz2mel(fmax), n + 2)
    return np.array([mel2hz(m) for m in pts[1:-1]])


def _htk_centres(n=64, lo=30.0, hi=11000.0):
    h2m = lambda f: 2595 * np.log10(1 + f / 700); m2h = lambda m: 700 * (10 ** (m / 2595) - 1)
    pts = np.linspace(h2m(lo), h2m(hi), n + 2)
    return m2h(pts[1:-1])


def envelopes_from_power(P, centres):
    """[bands, T] power -> [T, BANDS] log band energy."""
    g = _group(centres)
    E = np.zeros((BANDS, P.shape[1]))
    np.add.at(E, g, P)
    return np.log(E.T + 1e-8).astype(np.float32)


def env_harmonix(fid):
    """Band envelopes of the annotated Harmonix audio (melspec), times = k / ENV_FPS."""
    return envelopes_from_power(np.load(f"{MELDIR}/{fid}-mel.npy"), _slaney_centres()), 0.0


def env_choreo(name, speed=1.0):
    """Band envelopes from Choreo's own 100 fps features (as the app would compute them),
    resampled to the common grid. Returns (E, t0): frame k is at t0 + k / ENV_FPS."""
    x, off = load_feats(name, speed)
    mag = np.expm1(np.maximum(x[:, :64], 0))           # area-normalised band magnitude (x const)
    t = off + np.arange(len(x)) / FPS
    tk = np.arange(t[0], t[-1], 1 / ENV_FPS)
    # Harmonix frames use a 93 ms window; average Choreo's 100 fps power over the same span.
    k9 = np.ones(9) / 9
    P = np.stack([np.interp(tk, t, np.convolve(mag[:, b] ** 2, k9, mode="same")) for b in range(64)])
    return envelopes_from_power(P, _htk_centres()), float(tk[0])


def load_feats(name, speed=1.0):
    f = f"{ML}/features/harmonix/{name}@{speed}.bin"
    T, D = np.fromfile(f, dtype=np.int32, count=2)
    off = float(np.fromfile(f, dtype=np.float32, count=1, offset=8)[0])
    return np.fromfile(f, dtype=np.float32, offset=12).reshape(T, D), off


def beat_features(E, t0, beats, downs):
    """One row per beat interval [b_i, b_i+1) from band log-energy envelopes E [T, BANDS] (frame k
    at t0 + k / ENV_FPS): band levels, band onsets (positive differences), overall level and onset
    peak, all relative to a causal running average (so source/level/tilt differences cancel);
    plus bar position, tempo, and repetition against 1/2/4/8 bars earlier."""
    flux = np.maximum(0, np.diff(E, axis=0, prepend=E[:1]))
    rows = []
    T = len(E)
    for i in range(len(beats) - 1):
        a = min(T - 1, max(0, int(round((beats[i] - t0) * ENV_FPS))))
        b = min(T, max(a + 1, int(round((beats[i + 1] - t0) * ENV_FPS))))
        e, d = E[a:b], flux[a:b]
        rows.append(np.concatenate([e.mean(0), d.mean(0), [e.mean(), d.sum(1).max()]]))
    r = np.array(rows, np.float32)
    ema, rel, k = r[0].copy(), np.zeros_like(r), 2 / (EMA_BEATS + 1)
    for i in range(len(r)):
        rel[i] = r[i] - ema
        ema += k * (r[i] - ema)
    pos, dl, j = np.zeros(len(r), int), sorted(downs), -1
    for i in range(len(r)):
        while j + 1 < len(dl) and dl[j + 1] <= beats[i] + 0.05:
            j += 1
        pos[i] = (sum(1 for t in beats[:i + 1] if t >= dl[j] - 0.05) - 1) % 4 if j >= 0 else i % 4
    onehot = np.eye(4, dtype=np.float32)[pos]
    ibi = np.diff(beats).astype(np.float32)
    tempo = np.log2(60 / np.maximum(ibi, 0.2) / 120)[:, None]
    z = rel / (np.abs(rel).mean(0, keepdims=True) + 1e-3)
    rep = np.zeros((len(r), len(REP_BARS) + 1), np.float32)
    for i in range(len(r)):
        for kk, nb in enumerate(REP_BARS):
            jj = i - 4 * nb
            rep[i, kk] = np.sqrt(((z[i] - z[jj]) ** 2).mean()) if jj >= 0 else 1.0
        rep[i, -1] = np.sqrt(((z[i] - z[max(0, i - 16):i].mean(0)) ** 2).mean()) if i > 0 else 1.0
    return np.concatenate([rel, onehot, tempo, rep], 1)


def boundary_times(song, lift=False, E=None, t0=0.0):
    """Section starts (recording time). lift=True: only the big ones, i.e. into a chorus/drop or a
    loudness jump of LIFT_DELTA or more (8 s after vs 8 s before)."""
    segs = [(t, l) for t, l in song["segments"] if not any(l.startswith(s) for s in SKIP_LABELS)]
    out = []
    for k, (t, l) in enumerate(segs):
        if k == 0 or t <= 2.0:
            continue
        if lift:
            base = l.rstrip("0123456789")
            big = base in ("chorus", "drop") and not segs[k - 1][1].startswith("chorus")
            if E is not None:
                lvl, i, w = E.mean(1), int((t - t0) * ENV_FPS), int(8 * ENV_FPS)
                if i >= w and i + w <= len(lvl):
                    big = big or (lvl[i:i + w].mean() - lvl[i - w:i].mean()) >= LIFT_DELTA * LIFT_SCALE
            if not big:
                continue
        out.append(t)
    return out


def beat_labels(beats, bounds, tol=0.12):
    y = np.zeros(len(beats), np.float32)
    b = np.array(beats)
    for t in bounds:
        j = int(np.abs(b - t).argmin())
        if abs(b[j] - t) < tol:
            y[j] = 1
    return y


class SectionNet(nn.Module):
    def __init__(self, h=64):
        super().__init__()
        self.inp = nn.Linear(D_IN, h)
        self.gru = nn.GRU(h, h, batch_first=True)
        self.out = nn.Linear(h, N_OUT)

    def forward(self, x):
        y, _ = self.gru(torch.tanh(self.inp(x)))
        return self.out(y)


def recorded(split):
    """Recorded (Spotify) Harmonix songs aligned to their annotations: tested through Choreo's own
    features and tracker, exactly like the app."""
    sp = json.load(open(os.path.join(ROOT, "tools", "ml", "split.json")))[split]
    return [dict(s, src="rec") for s in json.load(open(ALIGNED)) if s["name"] in sp]


def harmonix_songs(part):
    """All Harmonix Set songs from their melspecs + annotations (no recording needed). Songs in the
    recorded val/test splits are excluded so those stay unseen. part: train | val (10% by hash)."""
    import hashlib, glob
    held = {s["name"] for s in recorded("val") + recorded("test")}
    out = []
    for f in sorted(glob.glob(f"{HX}/harmonixset-main/dataset/beats_and_downbeats/*.txt")):
        fid = os.path.basename(f)[:-4]
        if fid in held or not os.path.exists(f"{MELDIR}/{fid}-mel.npy"):
            continue
        isval = int(hashlib.md5(("sec:" + fid).encode()).hexdigest(), 16) % 10 == 0
        if (part == "val") != isval:
            continue
        beats, downs = [], []
        for line in open(f):
            q = line.split()
            if len(q) >= 2:
                beats.append(float(q[0]))
                if q[1] == "1": downs.append(float(q[0]))
        segs = []
        sp = f"{HX}/harmonixset-main/dataset/segments/{fid}.txt"
        for line in open(sp) if os.path.exists(sp) else []:
            q = line.split(maxsplit=1)
            if len(q) == 2: segs.append((float(q[0]), q[1].strip()))
        if len(beats) > 40 and len(segs) > 1:
            out.append(dict(name=fid, src="hx", beats=beats, downbeats=downs, segments=segs,
                            spans=[[0.0, beats[-1] + 1]]))
    return out


def envelopes(song, speed=1.0):
    if song["src"] == "hx":
        E, t0 = env_harmonix(song["name"])
        if speed != 1.0:                                  # time-stretch the envelopes
            k = np.arange(0, (len(E) - 1) / speed) * speed
            i0 = np.minimum(k.astype(int), len(E) - 2); f = (k - i0)[:, None]
            E = (E[i0] * (1 - f) + E[i0 + 1] * f).astype(np.float32)
        return E, t0
    return env_choreo(song["name"], speed)


def example(song, speed=1.0):
    E, t0 = envelopes(song, speed)
    E1, t01 = envelopes(song) if speed != 1.0 else (E, t0)
    beats = [t / speed for t in song["beats"]]
    downs = [t / speed for t in song["downbeats"]]
    inside = lambda t: any(a <= t * speed < b for a, b in song["spans"])
    f = beat_features(E, t0, beats, downs)
    ys = []
    for lift in (False, True):
        yb = beat_labels(beats, [t / speed for t in boundary_times(song, lift, E1, t01)])
        ys += [np.append(yb[1:len(f) + 1], 0)[:len(f)], yb[:len(f)]]
    y = np.stack([ys[0], ys[2], ys[1], ys[3]], 1)           # next_any, next_lift, conf_any, conf_lift
    m = np.array([inside(t) for t in beats[:len(f)]], np.float32)
    return f, y, m


HEADS = ("next_any", "next_lift", "conf_any", "conf_lift")


def fit(train_songs, epochs, log=None, seed=0):
    random.seed(seed); torch.manual_seed(seed)
    speeds = (0.9, 1.0, 1.1)
    data = [example(s, sp) for s in train_songs for sp in speeds]
    model = SectionNet()
    opt = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-2)
    for ep in range(epochs):
        random.shuffle(data)
        model.train(); losses = []
        for f, y, m in data:
            x = torch.from_numpy(f).unsqueeze(0); yt = torch.from_numpy(y).unsqueeze(0); mt = torch.from_numpy(m)[None, :, None]
            x = x + 0.05 * torch.randn_like(x)                 # feature noise (small dataset)
            lg = model(x)
            w = (1 + 19 * yt) * mt
            loss = (F.binary_cross_entropy_with_logits(lg, yt, reduction="none") * w).sum() / w.sum().clamp(min=1)
            opt.zero_grad(); loss.backward(); nn.utils.clip_grad_norm_(model.parameters(), 1.0); opt.step()
            losses.append(loss.item())
        if log: log(ep, float(np.mean(losses)), model)
    return model


def tracker_beats(song):
    out = subprocess.run([os.path.join(ROOT, "build", "choreo-analyze"), song["wav"], "--beats"], capture_output=True, text=True).stdout
    beats, downs, mode = [], [], None
    for line in out.splitlines():
        if line.startswith("#"):
            mode = line[1:].strip(); continue
        p = line.split()
        if mode == "beats" and len(p) == 2: beats.append(float(p[0]))
        elif mode == "downbeats" and len(p) == 1: downs.append(float(p[0]))
    return beats, downs


def fire(p, thr):
    out, last = [], -10**9
    for i, v in enumerate(p):
        if v >= thr and i - last >= REFRACTORY:
            out.append(i); last = i
    return out


def score_events(times, refs, ibi, dur):
    used, hits = set(), 0
    for t in times:
        for k, r in enumerate(refs):
            if k not in used and abs(t - r) <= ibi * 1.0 + 0.03:
                used.add(k); hits += 1; break
    return hits, len(times), len(refs), dur


@torch.no_grad()
def predictions(model, items, live=True):
    """Per song: candidate events per head, as (time, probability), only on downbeats (the
    tracker's when live), plus the reference boundaries and the scored duration."""
    model.eval()
    out = []
    for s in items:
        E, t0 = envelopes(s)
        beats, downs = tracker_beats(s) if live else (s["beats"], s["downbeats"])
        if len(beats) < 40:
            continue
        f = beat_features(E, t0, beats, downs)
        p = torch.sigmoid(model(torch.from_numpy(f).unsqueeze(0)))[0].numpy()
        dset = np.array(downs)
        is_down = lambda t: len(dset) and np.abs(dset - t).min() < 0.05
        inside = lambda t: any(a + 2 <= t < b - 2 for a, b in s["spans"])
        ev = {h: [] for h in HEADS}
        for i in range(len(f)):
            if i + 1 < len(beats) and is_down(beats[i + 1]) and inside(beats[i + 1]):
                ev["next_any"].append((beats[i + 1], p[i, 0])); ev["next_lift"].append((beats[i + 1], p[i, 1]))
            if is_down(beats[i]) and inside(beats[i]):
                ev["conf_any"].append((beats[i], p[i, 2])); ev["conf_lift"].append((beats[i], p[i, 3]))
        refs = {False: [t for t in boundary_times(s) if inside(t)], True: [t for t in boundary_times(s, True, E, t0) if inside(t)]}
        out.append(dict(name=s["name"], ev=ev, refs=refs, ibi=float(np.median(np.diff(beats))),
                        dur=sum(b - a for a, b in s["spans"])))
    return out


def score(preds, head, thr):
    lift = head.endswith("lift")
    H = NE = NR = 0; dur = 0.0
    for r in preds:
        cand = [(t, v) for t, v in r["ev"][head] if v >= thr]
        fired, last = [], -1e9
        for t, v in cand:                                  # refractory: one cut per REFRACTORY beats
            if t - last >= REFRACTORY * r["ibi"] - 0.05:
                fired.append(t); last = t
        h, ne, nr, d = score_events(fired, r["refs"][lift], r["ibi"], r["dur"])
        H += h; NE += ne; NR += nr; dur += d
    P = H / NE if NE else 0; R = H / NR if NR else 0
    return P, R, (2 * P * R / (P + R) if P + R else 0), (NE - H) / (dur / 60) if dur else 0


def best_thr(preds, head):
    return max(((score(preds, head, t)[2], t) for t in np.arange(0.1, 0.96, 0.05)))


def report(preds, tag, thrs=None):
    for h in HEADS:
        if thrs:
            t = thrs[h]
        else:
            _, t = best_thr(preds, h)
        P, R, Fm, fpm = score(preds, h, t)
        print(f"{tag:22s} {h:9s} thr {t:.2f}  P {P:.2f}  R {R:.2f}  F {Fm:.3f}  false cuts/min {fpm:.2f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd"); ap.add_argument("split", nargs="?", default="test")
    ap.add_argument("--epochs", type=int, default=12)
    args = ap.parse_args()
    path = os.path.join(ROOT, "models", "sections.pt")
    if args.cmd == "train":
        tr, va = harmonix_songs("train"), harmonix_songs("val")
        print(f"train {len(tr)} Harmonix songs (melspecs), select on {len(va)}", flush=True)
        best = [-1]
        def log(ep, loss, model):
            pv = predictions(model, va, live=False)
            sc = {h: best_thr(pv, h) for h in HEADS}
            tot = sum(v[0] for v in sc.values())
            msg = f"epoch {ep + 1:2d} loss {loss:.4f} val " + " ".join(f"{h} {v[0]:.3f}" for h, v in sc.items())
            if tot > best[0]:
                best[0] = tot
                torch.save(model.state_dict(), path)
                json.dump({h: float(v[1]) for h, v in sc.items()}, open(path + ".thr.json", "w"))
                msg += " * saved"
            print(msg, flush=True)
        fit(tr, args.epochs, log)
    else:
        model = SectionNet(); model.load_state_dict(torch.load(path))
        thrs = json.load(open(path + ".thr.json"))
        items = recorded(args.split)
        report(predictions(model, items, live=False), f"{args.split} rec, annot beats", thrs)
        report(predictions(model, items, live=True), f"{args.split} rec, tracker", thrs)
        report(predictions(model, items, live=True), f"{args.split} rec, tracker*")   # * = threshold tuned here


if __name__ == "__main__":
    main()
