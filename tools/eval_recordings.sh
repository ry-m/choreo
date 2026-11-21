#!/bin/bash
# Offline re-scoring of live captures made with `choreo-live-eval --record DIR`.
# Usage: tools/eval_recordings.sh DIR [extra choreo-analyze args]
# Looks up each DIR/<title>.wav's reference BPM in tests/reference/spotify*.csv.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$1"; shift
for wav in "$DIR"/*.wav; do
  title=$(basename "$wav" .wav)
  bpm=$(grep -h -F ",$title," "$ROOT"/tests/reference/spotify*.csv | head -1 | awk -F, '{print $4}')
  [ -z "$bpm" ] && { printf '%-28s no reference\n' "$title"; continue; }
  r=$("$ROOT/build/choreo-analyze" "$wav" --ref-bpm "$bpm" "$@" | grep '^ref' |
      sed -E 's/ref ([0-9.]+) BPM: beat present ([0-9]+)% of the time; while present, correct ([0-9.]+)%, correct-or-half\/double ([0-9.]+)%; first correct at ([-0-9.]+)s; final ([0-9.]+)/ref \1  present \2%  correct \3%  half\/dbl \4%  first-ok \5s  final \6/')
  printf '%-28.28s %s\n' "$title" "$r"
done | tee /dev/stderr | awk '{for(i=1;i<=NF;i++){if($i=="correct"){c+=$(i+1);n++} if($i=="half/dbl"){h+=$(i+1)}}} END {if(n) printf "\nMEAN over %d: correct %.1f%%, correct-or-half/double %.1f%%\n", n, c/n, h/n}'
