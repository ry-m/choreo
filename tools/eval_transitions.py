#!/usr/bin/env python3
# Joins pairs of recordings (A's last 30 s, then B with no gap) and scores how fast Choreo
# re-locks on B. usage: transitions.py ["ENV=.."...]  (V=1 for per-pair rows)
import os, re, subprocess, sys, glob, wave, random, statistics as st
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REC = os.environ.get("CHOREO_REC_DIR", os.path.expanduser("~/.cache/choreo/rec"))
TMP = os.path.join(REC, "..", "pairs")
os.makedirs(TMP, exist_ok=True)
refs = {}
for f in [ROOT + "/tests/reference/spotify.csv", ROOT + "/tests/reference/spotify_broad.csv"] + (glob.glob(ROOT + "/tests/reference/spotify_more.csv") if os.environ.get("MORE") else []):
    for line in open(f):
        if line.startswith("#") or line.startswith("uri,"): continue
        p = line.rstrip("\n").split(",")
        if len(p) >= 4 and p[3]: refs[p[1]] = float(p[3])
SKIP = {"Opus"}
wavs = [w for w in sorted(glob.glob(REC + "/*.wav")) if os.path.basename(w)[:-4] in refs and os.path.basename(w)[:-4] not in SKIP]
rnd = random.Random(1)
pairs = []
for _ in range(40):
    a, b = rnd.sample(wavs, 2)
    ra, rb = refs[os.path.basename(a)[:-4]], refs[os.path.basename(b)[:-4]]
    if abs(ra / rb - 1) < 0.06 or abs(ra / rb / 2 - 1) < 0.06 or abs(rb / ra / 2 - 1) < 0.06: continue  # same tempo: not a test
    pairs.append((a, b))
pairs = pairs[:30]
def read(p):
    w = wave.open(p); sr = w.getframerate(); d = w.readframes(w.getnframes()); w.close(); return sr, d
for i, (a, b) in enumerate(pairs):
    out = f"{TMP}/" + (os.path.basename(a)[:-4] + "__" + os.path.basename(b)[:-4]).replace(" ", "_") + ".wav"
    if os.path.exists(out): continue
    sra, da = read(a); srb, db = read(b)
    da = da[-30 * sra * 2:]  # last 30 s of A: tempo well established
    o = wave.open(out, "wb"); o.setnchannels(1); o.setsampwidth(2); o.setframerate(sra); o.writeframes(da + db); o.close()
for cfg in sys.argv[1:] or [""]:
    env = dict(os.environ); env.update(kv.split("=", 1) for kv in cfg.split())
    locks, acc2, rows = [], [], []
    for i, (a, b) in enumerate(pairs):
        tb = os.path.basename(b)[:-4]
        pf = f"{TMP}/" + (os.path.basename(a)[:-4] + "__" + os.path.basename(b)[:-4]).replace(" ", "_") + ".wav"
        out = subprocess.run([ROOT + "/build/choreo-analyze", pf, "--ref-bpm", str(refs[tb]), "--from", "30"], env=env, capture_output=True, text=True).stdout
        m = re.search(r"correct ([\d.]+)%, correct-or-half/double ([\d.]+)%; first correct at [-\d.]+s; final [\d.]+; first half/double-ok at ([-\d.]+)s", out)
        e, h, f = map(float, m.groups()) if m else (0, 0, -1)
        acc2.append(h); rows.append((os.path.basename(a)[:-4], tb, h, f))
        locks.append(f if f >= 0 else 75)
    print(f"{cfg or 'default':44s} pairs={len(pairs)} acc2 on B {st.mean(acc2):5.1f}%  median first-ok(acc2) {st.median(locks):4.1f}s  >10s: {sum(l > 10 for l in locks)}")
    if os.environ.get("V"):
        for r in sorted(rows, key=lambda r: -(r[3] if r[3] >= 0 else 99))[:10]: print(f"     {r[0][:18]:18s} -> {r[1][:22]:22s} acc2 {r[2]:5.1f} first-ok {r[3]:5.1f}")
