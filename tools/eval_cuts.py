#!/usr/bin/env python3
"""Score the scene director's cuts on recorded Harmonix songs (headless, via choreo-render --events).

For every director cut: does it land on a beat of the analyser's grid (and on the downbeat for
immediate cuts, one beat after it for confirmed ones)? Is the section downbeat it belongs to within
±1 beat of an annotated Harmonix boundary (any / lift)? Plus how many annotated lifts got a cut, and
cut / transition rates. Usage: .venv/bin/python tools/eval_cuts.py [val|test] [ENV=VALUE ...]
"""
import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools", "ml"))
import sections as S  # noqa: E402


def run(song, env):
    out = subprocess.run([os.path.join(ROOT, "build", "choreo-render"), song["wav"], "--events"],
                         capture_output=True, text=True, env=env).stdout
    ev, beats, downs, mode = [], [], [], None
    for line in out.splitlines():
        if line.startswith("#"):
            mode = line[1:].split()[0]; continue
        q = line.split()
        if mode == "director": ev.append((float(q[0]), q[1], int(q[3]), int(q[4]), " ".join(q[6:])))
        elif mode == "beats": beats.append(float(q[0]))
        elif mode == "downbeats": downs.append(float(q[0]))
    return song, ev, np.array(beats), np.array(downs)


def main():
    split = next((a for a in sys.argv[1:] if "=" not in a), "test")
    env = dict(os.environ, **dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a))
    songs = S.recorded(split)
    with ThreadPoolExecutor(8) as ex:
        results = list(ex.map(lambda s: run(s, env), songs))

    n = {"cut": 0, "change": 0, "hit": 0, "phrase": 0}
    on_beat = on_down = conf_after_down = 0
    offs, hit_any, hit_lift, cuts_scored = [], 0, 0, 0
    lift_refs = lift_refs_cut = 0
    minutes = 0.0
    confirmed = 0
    for song, ev, beats, downs in results:
        if len(beats) < 40: continue
        E, t0 = S.envelopes(song)
        inside = lambda t: any(a + 2 <= t < b - 2 for a, b in song["spans"])
        ibi = float(np.median(np.diff(beats)))
        minutes += sum(b - a for a, b in song["spans"]) / 60
        refs_any = [t for t in S.boundary_times(song, False, E, t0) if inside(t)]
        refs_lift = [t for t in S.boundary_times(song, True, E, t0) if inside(t)]
        cut_sections = []
        for t, kind, beat_count, in_bar, why in ev:
            if not inside(t): continue
            n[kind] = n.get(kind, 0) + 1
            if kind != "cut": continue
            # The beat it was triggered by: the last analyser beat at or before the cut. Beat events
            # reach the display ~30-45 ms after the beat (the detector's causal latency), so "on the
            # beat" means within 60 ms after it.
            k = max(0, int(np.searchsorted(beats, t + 0.005)) - 1)
            off = t - beats[k]
            offs.append(off * 1000)
            on_beat += 0 <= off < 0.06
            on_down += 0 <= off < 0.06 and len(downs) > 0 and np.min(np.abs(downs - beats[k])) < 0.005
            # The downbeat this cut belongs to: itself, or the beat before for confirmed cuts.
            sec = t
            if "confirmed" in why and k > 0:
                sec = beats[k - 1]
                conf_after_down += len(downs) > 0 and np.min(np.abs(downs - sec)) < 0.005
            confirmed += "confirmed" in why
            cut_sections.append(sec)
            cuts_scored += 1
            hit_any += any(abs(sec - r) <= ibi + 0.03 for r in refs_any)
            hit_lift += any(abs(sec - r) <= ibi + 0.03 for r in refs_lift)
        lift_refs += len(refs_lift)
        lift_refs_cut += sum(any(abs(c - r) <= ibi + 0.03 for c in cut_sections) for r in refs_lift)

    c = max(cuts_scored, 1)
    print(f"{split}: {len(results)} songs, {minutes:.1f} min")
    print(f"  cuts {n['cut']} ({n['cut'] / minutes:.2f}/min), smaller changes {n['change']} ({n['change'] / minutes:.2f}/min), "
          f"lift hits {n['hit']} ({n['hit'] / minutes:.2f}/min), phrase accents {n['phrase']} ({n['phrase'] / minutes:.2f}/min)")
    print(f"  cut within 60 ms after an analyser beat: {on_beat / c:.0%}   on a downbeat: {on_down / c:.0%}   "
          f"confirmed cuts one beat after a downbeat: {conf_after_down}/{confirmed}")
    if offs: print(f"  cut − nearest beat: median {np.median(offs):+.1f} ms, max |{np.max(np.abs(offs)):.1f}| ms")
    print(f"  cut's section downbeat within ±1 beat of an annotated boundary: {hit_any / c:.0%} (any), {hit_lift / c:.0%} (lift)")
    print(f"  annotated lifts that got a cut: {lift_refs_cut}/{lift_refs} ({lift_refs_cut / max(lift_refs, 1):.0%})")


if __name__ == "__main__":
    main()
