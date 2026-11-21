#!/usr/bin/env python3
# usage: sweep.py "ENV=.. ENV2=.." ...  -> mean scores over recordings (Opus excluded), tests, Black Ops 2
import os, re, subprocess, sys, statistics as st, glob, csv
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REC = os.environ.get("CHOREO_REC_DIR", os.path.expanduser("~/.cache/choreo/rec"))
refs = {}
for f in glob.glob(ROOT + "/tests/reference/spotify*.csv"):
    for line in open(f):
        if line.startswith("#") or line.startswith("uri,"): continue
        p = line.rstrip("\n").split(",")
        if len(p) >= 4 and p[3]: refs[p[1]] = float(p[3])
SKIP = {"Opus"}  # accelerating intro: a single reference BPM doesn't apply
verbose = os.environ.get("V")
for cfg in sys.argv[1:]:
    env = dict(os.environ); env.update(kv.split("=", 1) for kv in cfg.split())
    ex, hd, fo, rows = [], [], [], []
    for wav in sorted(glob.glob(REC + "/*.wav")):
        t = os.path.basename(wav)[:-4]
        if t in SKIP or t not in refs: continue
        out = subprocess.run([ROOT + "/build/choreo-analyze", wav, "--ref-bpm", str(refs[t])], env=env, capture_output=True, text=True).stdout
        m = re.search(r"correct ([\d.]+)%, correct-or-half/double ([\d.]+)%; first correct at [-\d.]+s; final ([\d.]+); first half/double-ok at ([-\d.]+)s", out)
        if not m: ex.append(0); hd.append(0); rows.append((t, 0, 0, -1, 0)); continue
        e, h, fin, f = map(float, m.groups()); ex.append(e); hd.append(h)
        if f >= 0: fo.append(f)
        rows.append((t, e, h, f, fin))
    tests = subprocess.run([ROOT + "/build/test_analysis"], env=env, capture_output=True, text=True).stdout
    fails = [l for l in tests.splitlines() if l.startswith("FAIL")]
    bo = subprocess.run([ROOT + "/tools/eval_tempo.sh"], env=env, capture_output=True, text=True).stdout
    b = re.search(r"Black Ops 2.*?correct ([\d.]+)%", bo)
    print(f"{cfg:44s} n={len(ex)} exact {st.mean(ex):5.1f}%  half/dbl {st.mean(hd):5.1f}%  median first-ok(acc2) {st.median(fo):4.1f}s  never {len(ex)-len(fo)} | fails {len(fails)} | BO2 {b.group(1) if b else '?'}%")
    for f in fails: print("     ", f)
    if verbose:
        for r in sorted(rows, key=lambda r: r[1])[:12]: print(f"     {r[0][:26]:26s} exact {r[1]:5.1f} half/dbl {r[2]:5.1f} first {r[3]:5.1f} final {r[4]:.1f}")
