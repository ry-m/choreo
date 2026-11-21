#!/usr/bin/env python3
"""Build training data for the learned beat detector.

For every annotated clip (GTZAN, Ballroom) this runs the C++ feature extractor
(build/choreo-features, the same code the app uses) and stores per-frame beat/downbeat
targets. Training clips are rendered at several speeds (tempo augmentation) and gains.

Output: $CHOREO_ML/features/<set>/<name>@<speed>.bin  (+ index.json with labels)
The train/test split is deterministic and saved to tools/ml/split.json (commit it).
"""
import glob, hashlib, json, os, random, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.environ.get("CHOREO_DATA", os.path.expanduser("~/.cache/choreo/datasets"))
ML = os.environ.get("CHOREO_ML", os.path.expanduser("~/.cache/choreo/ml"))
BIN = os.path.join(ROOT, "build", "choreo-features")
SPEEDS = [0.86, 0.93, 1.0, 1.07, 1.15]
TEST_FRACTION = 0.15


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
    return sorted(out)


def is_test(name):
    return int(hashlib.md5(name.encode()).hexdigest(), 16) % 1000 < TEST_FRACTION * 1000


def main():
    items = clips()
    split = {"test": sorted(n for _, n, _, _ in items if is_test(n))}
    split["train"] = sorted(n for _, n, _, _ in items if not is_test(n))
    json.dump(split, open(os.path.join(ROOT, "tools", "ml", "split.json"), "w"), indent=0)
    print(f"{len(items)} clips: {len(split['train'])} train, {len(split['test'])} test")

    jobs, index = [], []
    rnd = random.Random(0)
    for ds, name, wav, ann in items:
        beats, downs = read_beats(ann)
        test = is_test(name)
        for sp in ([1.0] if test else SPEEDS):
            gain = 0.0 if test else rnd.uniform(-9, 9)
            out = f"{ML}/features/{ds}/{name}@{sp}.bin"
            os.makedirs(os.path.dirname(out), exist_ok=True)
            jobs.append((wav, out, sp, gain))
            index.append(dict(set=ds, name=name, file=out, speed=sp, test=test,
                              beats=[t / sp for t in beats], downbeats=[t / sp for t in downs]))

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
