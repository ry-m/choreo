#!/bin/bash
# Overnight, silent recording of the Harmonix songs queued in tests/reference/harmonix_spotify.csv.
# - Spotify's audio is captured through a muted per-app tap (nothing reaches the speakers), and the
#   system output is muted as well for the duration, then restored.
# - Resumable: already-recorded songs are skipped. Spotify is paused when this ends for any reason.
# Recordings go to $CHOREO_HX_REC (default ~/.cache/choreo/harmonix_rec); never commit them.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REC="${CHOREO_HX_REC:-$HOME/.cache/choreo/harmonix_rec}"
mkdir -p "$REC"
WAS_MUTED=$(osascript -e 'output muted of (get volume settings)')
restore() {
  osascript -e 'tell application "Spotify" to pause' >/dev/null 2>&1
  osascript -e "set volume output muted $WAS_MUTED" >/dev/null 2>&1
  echo "[record_harmonix] finished $(date); system mute restored to $WAS_MUTED"
}
trap restore EXIT
osascript -e 'set volume with output muted'
echo "[record_harmonix] started $(date); recording to $REC"
"$ROOT/build/choreo-live-eval" "$ROOT/tests/reference/harmonix_spotify.csv" --full --record "$REC" --skip-existing \
  --out "$REC/live_results.csv"
