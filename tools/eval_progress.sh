#!/bin/bash
# Live progress view for choreo-live-eval runs.
# Usage: eval_progress.sh SECONDS_PER_TRACK LOG1 CSV1 [LOG2 CSV2 ...]
# Follows each run in turn (waiting for a log to appear), showing an overall bar, the track
# Spotify is playing now, and results so far.
secs="$1"; shift
phases=$(( $# / 2 ))

count_tracks() { grep -v '^#' "$1" | grep -v '^uri,' | grep -c ','; }
bar() { # fraction(0-1) width
  awk -v f="$1" -v w="$2" 'BEGIN { n = int(f * w + 0.5); s = ""; for (i = 0; i < w; i++) s = s (i < n ? "█" : "░"); printf "%s", s }'
}

phase=0
while [ $# -ge 2 ]; do
  log="$1"; csv="$2"; shift 2
  phase=$((phase + 1))
  total=$(count_tracks "$csv")
  while :; do
    done_n=0; [ -f "$log" ] && done_n=$(grep -c ' ref ' "$log")
    now=$(osascript -e 'tell application "Spotify" to (name of current track) & "|" & (artist of current track) & "|" & (player position as integer) & "|" & (player state as string)' 2>/dev/null)
    IFS='|' read -r title artist pos state <<< "$now"
    pos=${pos:-0}; [ "$pos" -gt "$secs" ] && pos=$secs
    frac=$(awk -v d="$done_n" -v p="$pos" -v s="$secs" -v t="$total" 'BEGIN { f = (d + (d < t ? p / s : 0)) / t; if (f > 1) f = 1; print f }')
    left=$(awk -v d="$done_n" -v p="$pos" -v s="$secs" -v t="$total" 'BEGIN { r = (t - d) * (s + 4) - p; if (r < 0) r = 0; printf "%d:%02d", r / 60, r % 60 }')
    clear
    printf '\n  Choreo live eval — run %d of %d (%s)\n\n' "$phase" "$phases" "$(basename "$csv")"
    printf '  %s  %3.0f%%\n' "$(bar "$frac" 40)" "$(awk -v f="$frac" 'BEGIN { print f * 100 }')"
    printf '  %d / %d tracks done · ~%s left in this run\n\n' "$done_n" "$total" "$left"
    if [ ! -f "$log" ]; then
      printf '  Waiting for this run to start…\n'
    elif [ "$done_n" -lt "$total" ] && ! grep -q '^MEAN' "$log"; then
      printf '  Now: %s — %s\n' "${title:-?}" "${artist:-?}"
      printf '  %s  %ds / %ds  (%s)\n\n' "$(bar "$(awk -v p="$pos" -v s="$secs" 'BEGIN { print p / s }')" 20)" "$pos" "$secs" "${state:-?}"
    fi
    if [ -f "$log" ]; then
      printf '  %-28s %6s %6s %8s %8s %8s\n' TRACK REF FINAL PRESENT CORRECT RELATED
      grep ' ref ' "$log" | awk '{
        match($0, / ref /); name = substr($0, 1, RSTART - 1); sub(/ +$/, "", name)
        split(substr($0, RSTART), f, " +")
        printf "  %-28.28s %6s %6s %8s %8s %8s\n", name, f[3], f[5], f[7], f[9], f[11]
      }'
      grep '^MEAN' "$log" | sed 's/^/\n  /'
    fi
    if [ -f "$log" ] && grep -q '^MEAN' "$log"; then break; fi
    if [ -f "$log" ] && ! pgrep -f "choreo-live-eval .*$(basename "$csv")" >/dev/null && [ "$done_n" -ge 1 ]; then break; fi
    sleep 1
  done
  sleep 2
done
printf '\n  All runs finished.\n'
