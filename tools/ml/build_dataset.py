#!/usr/bin/env python3
"""Build training data for the learned beat detector.

For every annotated clip (GTZAN, Ballroom, and Harmonix songs recorded from Spotify and
aligned by harmonix.py) this runs the C++ feature extractor
(build/choreo-features, the same code the app uses) and stores per-frame beat/downbeat
targets. Training clips are rendered at several speeds (tempo augmentation) and gains.

Output: $CHOREO_ML/features/<set>/<name>@<speed>.bin  (+ index.json with labels)
Splits are deterministic (hash of the name) and saved to tools/ml/split.json (commit it):
  test  held out for reporting only; val  used to pick the best epoch; train  the rest.
Harmonix clips carry "spans": labels are trusted only inside them (the loss is masked elsewhere).
"""
import glob, hashlib, json, os, random, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.environ.get("CHOREO_DATA", os.path.expanduser("~/.cache/choreo/datasets"))
ML = os.environ.get("CHOREO_ML", os.path.expanduser("~/.cache/choreo/ml"))
BIN = os.path.join(ROOT, "build", "choreo-features")
SPEEDS = [0.86, 0.93, 1.0, 1.07, 1.15]
TEST_FRACTION = 0.15
VAL_FRACTION = 0.10
HX_TEST_FRACTION = 0.20   # Harmonix is the modern pop/EDM benchmark: hold out a bigger share


def read_beats(path):
    beats, downs = [], []
    for line in open(path, errors="ignore"):
        p = line.replace(",", " ").split()
        if not p:
            continue
        t = float(p[0])
        beats.append(t)
        if len(p) > 1 and p[1].split(".")[0] == "1":
            downs.append(t)
    return sorted(beats), sorted(downs)


def clips():
    out = []
    gtz = {os.path.basename(p)[:-4]: p for p in glob.glob(f"{DATA}/gtzan/genres/*/*.wav")}
    for b in glob.glob(f"{DATA}/gtzan/annotations/**/*.beats", recursive=True):
        name = re.sub(r"^gtzan_", "", os.path.basename(b)[:-6]).replace("_", ".")
        if name in gtz:
            out.append(("gtzan", name, gtz[name], b))
    bal = {os.path.basename(p)[:-4]: p for p in glob.glob(f"{DATA}/ballroom/audio/**/*.wav", recursive=True)}
    for b in glob.glob(f"{DATA}/ballroom/annotations/**/*.beats", recursive=True):
        name = os.path.basename(b)[:-6]
        if name in bal:
            out.append(("ballroom", name, bal[name], b))
    out = [(ds, n, w, a, None) for ds, n, w, a in sorted(out)]
    hx = f"{ML}/harmonix_aligned.json"
    if os.path.exists(hx):
        for d in json.load(open(hx)):
            out.append(("harmonix", d["name"], d["wav"],
                        (d["beats"], d["downbeats"] if d.get("downbeats_ok") else None), d["spans"]))
    return out


def split_of(ds, name):
    h = int(hashlib.md5(name.encode()).hexdigest(), 16) % 1000
    if h < (HX_TEST_FRACTION if ds == "harmonix" else TEST_FRACTION) * 1000:
        return "test"   # unchanged for GTZAN/Ballroom, so earlier test numbers stay comparable
    v = int(hashlib.md5(("val:" + name).encode()).hexdigest(), 16) % 1000
    return "val" if v < VAL_FRACTION * 1000 else "train"


def main():
    items = clips()
    split = {k: sorted(n for ds, n, *_ in items if split_of(ds, n) == k) for k in ("train", "val", "test")}
    json.dump(split, open(os.path.join(ROOT, "tools", "ml", "split.json"), "w"), indent=0)
    for ds in ("gtzan", "ballroom", "harmonix"):
        c = {k: sum(1 for d, n, *_ in items if d == ds and split_of(d, n) == k) for k in split}
        print(f"{ds:9s} train {c['train']:4d}  val {c['val']:3d}  test {c['test']:3d}")

    jobs, index = [], []
    rnd = random.Random(0)
    for ds, name, wav, ann, spans in items:
        beats, downs = read_beats(ann) if isinstance(ann, str) else ann
        sp_name = split_of(ds, name)
        test = sp_name != "train"
        for sp in ([1.0] if test else SPEEDS):
            gain = 0.0 if test else rnd.uniform(-9, 9)
            out = f"{ML}/features/{ds}/{name}@{sp}.bin"
            os.makedirs(os.path.dirname(out), exist_ok=True)
            jobs.append((wav, out, sp, gain))
            index.append(dict(set=ds, name=name, file=out, speed=sp, test=sp_name == "test", split=sp_name,
                              beats=[t / sp for t in beats],
                              downbeats=[t / sp for t in downs] if downs is not None else None,
                              spans=[[a / sp, b / sp] for a, b in spans] if spans else None))

    def run(j):
        wav, out, sp, gain = j
        if os.path.exists(out):
            return True
        r = subprocess.run([BIN, wav, out, "--speed", str(sp), "--gain", f"{gain:.2f}"], capture_output=True)
        return r.returncode == 0

    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        ok = list(ex.map(run, jobs))
    print(f"extracted {sum(ok)}/{len(ok)} feature files")
    json.dump(index, open(f"{ML}/features/index.json", "w"))


if __name__ == "__main__":
    main()
