#!/usr/bin/env python3
"""Beat-tracking evaluation against expert annotations (GTZAN, Ballroom, ...).

Runs choreo-analyze on every clip, compares Choreo's beats with the annotated beats and prints
standard metrics (as in mir_eval / MIREX), skipping the first 5 s like the literature does:

  F        F-measure, ±70 ms window
  CMLt     fraction of beats correct at the annotated metrical level (continuity-based)
  AMLt     same, but off-beat, double and half tempo also accepted
  offbeat  share of Choreo's beats that sit near the half-beat points (locked half a beat out)
  offset   median (Choreo - annotation) for matched beats, ms (+ = Choreo late)

Usage: eval_beats.py DATASET [ENV=VALUE ...]   (DATASET: gtzan | ballroom | harmonix | all)
       harmonix = Spotify recordings aligned by tools/ml/harmonix.py, scored inside verified spans
       V=1 for per-clip rows, LIMIT=n to use the first n clips, GENRE=pop to filter GTZAN,
       SPLIT=test to score only clips held out from training the learned detector.
Datasets are expected in $CHOREO_DATA (default ~/.cache/choreo/datasets), see load_* below.
"""
import glob, os, re, statistics as st, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.environ.get("CHOREO_DATA", os.path.expanduser("~/.cache/choreo/datasets"))
BIN = os.path.join(ROOT, "build", "choreo-analyze")
SKIP = 5.0


def read_beats(path):
    out = []
    for line in open(path, errors="ignore"):
        parts = line.replace(",", " ").split()
        if not parts:
            continue
        try:
            out.append(float(parts[0]))
        except ValueError:
            pass
    return sorted(out)


def load_gtzan():
    audio = {os.path.basename(p)[:-4]: p for p in glob.glob(f"{DATA}/gtzan/genres/*/*.wav") + glob.glob(f"{DATA}/gtzan/genres/*/*.au")}
    items = []
    for b in sorted(glob.glob(f"{DATA}/gtzan/annotations/**/*.beats", recursive=True)):
        name = re.sub(r"^gtzan_", "", os.path.basename(b).rsplit(".", 1)[0]).replace("_", ".")
        if name in audio:
            items.append((name, audio[name], b))
    g = os.environ.get("GENRE")
    return [i for i in items if not g or i[0].startswith(g + ".")]


def load_ballroom():
    audio = {os.path.basename(p)[:-4]: p for p in glob.glob(f"{DATA}/ballroom/audio/**/*.wav", recursive=True)}
    items = []
    for b in sorted(glob.glob(f"{DATA}/ballroom/annotations/**/*.beats", recursive=True)):
        name = os.path.basename(b)[:-6]
        if name in audio:
            items.append((name, audio[name], b))
    return items


def load_harmonix():
    import json
    p = os.path.join(os.environ.get("CHOREO_ML", os.path.expanduser("~/.cache/choreo/ml")), "harmonix_aligned.json")
    if not os.path.exists(p):
        return []
    return [(d["name"], d["wav"], (d["beats"], d["spans"])) for d in json.load(open(p))]


def trim(x):
    return [t for t in x if t >= SKIP]


def f_measure(est, ref, win=0.07):
    if not est or not ref:
        return 0.0
    used, hits = [False] * len(ref), 0
    for e in est:
        best, bi = win + 1, -1
        for i, r in enumerate(ref):
            d = abs(e - r)
            if d <= win and not used[i] and d < best:
                best, bi = d, i
        if bi >= 0:
            used[bi] = True
            hits += 1
    p, r = hits / len(est), hits / len(ref)
    return 2 * p * r / (p + r) if p + r else 0.0


def continuity_t(est, ref, thr=0.175):
    """Fraction of estimated beats that are correct against `ref`: within thr x local
    inter-beat interval of a reference beat, with the preceding interval also matching."""
    if len(est) < 2 or len(ref) < 2:
        return 0.0
    ok = 0
    j = 0
    for m in range(1, len(est)):
        while j + 1 < len(ref) and abs(ref[j + 1] - est[m]) <= abs(ref[j] - est[m]):
            j += 1
        if j == 0:
            continue
        ibi = ref[j] - ref[j - 1]
        if abs(est[m] - ref[j]) > thr * ibi:
            continue
        if abs((est[m] - est[m - 1]) - ibi) > thr * ibi:
            continue
        ok += 1
    return ok / max(len(est), len(ref))


def variations(ref):
    """Reference beats at other acceptable metrical levels/phases (for AMLt)."""
    mids = [(a + b) / 2 for a, b in zip(ref, ref[1:])]
    double = sorted(ref + mids)
    return [ref, mids, double, ref[0::2], ref[1::2]]


def analyse(item, env):
    name, audio, ann = item
    out = subprocess.run([BIN, audio, "--beats"], env=env, capture_output=True, text=True).stdout
    est, mode = [], None
    for line in out.splitlines():
        if line.startswith("#beats"):
            mode = "b"
            continue
        if mode == "b":
            p = line.split()
            if len(p) == 2:
                est.append(float(p[0]))
    if isinstance(ann, tuple):              # (beats, spans): score only inside verified spans
        beats, spans = ann
        inside = lambda t: any(a + 0.5 <= t < b - 0.5 for a, b in spans)
        ref, est = [t for t in trim(beats) if inside(t)], [t for t in trim(est) if inside(t)]
    else:
        ref = trim(read_beats(ann))
        est = trim(est)
    if len(ref) < 4:
        return None
    f = f_measure(est, ref)
    cml = continuity_t(est, ref)
    aml = max(continuity_t(est, v) for v in variations(ref))
    # Off-beat share and timing offset: classify each estimated beat by its nearest reference
    # beat vs nearest half-beat point.
    mids = [(a + b) / 2 for a, b in zip(ref, ref[1:])]
    off, offsets = 0, []
    for e in est:
        dr = min(ref, key=lambda r: abs(r - e))
        dm = min(mids, key=lambda r: abs(r - e)) if mids else 1e9
        if abs(e - dm) < abs(e - dr):
            off += 1
        elif abs(e - dr) <= 0.07:
            offsets.append((e - dr) * 1000)
    return dict(name=name, F=f, CMLt=cml, AMLt=aml, offbeat=off / len(est) if est else 0,
                offset=st.median(offsets) if offsets else float("nan"), n=len(est))


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    env = dict(os.environ)
    env.update(kv.split("=", 1) for kv in sys.argv[2:])
    sets = {"gtzan": load_gtzan, "ballroom": load_ballroom, "harmonix": load_harmonix}
    for ds in (sets if which == "all" else [which]):
        items = sets[ds]()
        if os.environ.get("SPLIT") in ("test", "train"):
            split = set(__import__("json").load(open(os.path.join(ROOT, "tools", "ml", "split.json")))[os.environ["SPLIT"]])
            items = [i for i in items if i[0] in split]
        if os.environ.get("LIMIT"):
            items = items[: int(os.environ["LIMIT"])]
        if not items:
            print(f"{ds}: no clips found under {DATA}/{ds}")
            continue
        with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
            rows = [r for r in ex.map(lambda it: analyse(it, env), items) if r]
        offs = [r["offset"] for r in rows if r["offset"] == r["offset"]]
        print(f"{ds:9s} n={len(rows):4d}  F {st.mean(r['F'] for r in rows):.3f}  CMLt {st.mean(r['CMLt'] for r in rows):.3f}  "
              f"AMLt {st.mean(r['AMLt'] for r in rows):.3f}  off-beat {100 * st.mean(r['offbeat'] for r in rows):4.1f}%  "
              f"clips mostly off-beat {sum(r['offbeat'] > 0.5 for r in rows):3d}  median offset {st.median(offs):+.1f} ms")
        if os.environ.get("V"):
            for r in sorted(rows, key=lambda r: r["AMLt"])[:15]:
                print(f"   {r['name']:28s} F {r['F']:.2f} CMLt {r['CMLt']:.2f} AMLt {r['AMLt']:.2f} off-beat {100 * r['offbeat']:3.0f}% offset {r['offset']:+.0f}")


if __name__ == "__main__":
    main()
