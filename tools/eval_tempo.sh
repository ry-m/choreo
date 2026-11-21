#!/bin/bash
# Scores tempo tracking on local reference tracks listed in tests/reference/tempos.csv.
# Audio isn't in the repo: files are looked up as "$CHOREO_MUSIC_DIR/<title>.<ext>"
# (default ~/Desktop). Extra args are passed to choreo-analyze.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MUSIC="${CHOREO_MUSIC_DIR:-$HOME/Desktop}"
BIN="$ROOT/build/choreo-analyze"
tail -n +2 "$ROOT/tests/reference/tempos.csv" | grep -v '^#' | grep -v '^title,' |
while IFS=, read -r title artist bpm source rest; do
  file=""
  for ext in mp3 m4a wav aiff flac; do
    [ -f "$MUSIC/$title.$ext" ] && file="$MUSIC/$title.$ext" && break
  done
  if [ -z "$file" ]; then printf '%-22s missing (looked in %s)\n' "$title" "$MUSIC"; continue; fi
  result=$("$BIN" "$file" --ref-bpm "$bpm" "$@" | grep '^ref')
  printf '%-22s [%s] %s\n' "$title" "$source" "$result"
done
