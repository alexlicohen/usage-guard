#!/bin/bash
# usage-guard — read or watch the live 5-hour "session" usage % (the same number the
# statusline shows), so a long background job can be stopped cleanly before the hard
# limit (e.g. Max plans with overflow disabled). Source of truth: ccstatusline, which
# fetches Anthropic's /api/oauth/usage itself.
#
#   bash usage_guard.sh --once          # print "Session% Weekly%" once; exit 0 if read,
#                                        # exit 2 (loud, to stderr) if usage is UNREADABLE
#   TRIP_PCT=95 bash usage_guard.sh     # poll every INTERVAL s; exit 0 when Session >= TRIP_PCT
#                                        # (a completion notification -> stop the job)
#   printf '%s' "<raw>" | bash usage_guard.sh --parse   # internal: parse raw text (for tests)
#
# FAIL-LOUD (a safety tool must never fail silent): if usage is unreadable at startup the
# guard refuses to arm (exit 2); if it goes blind for FAIL_MAX consecutive polls mid-run it
# exits loud (exit 3) instead of looping forever pretending to protect you.
#
# Env: TRIP_PCT (default 97), INTERVAL (default 15), WEEKLY_TRIP (default 101 = off),
#      FAIL_MAX (default 3 consecutive blind polls -> loud exit),
#      UG_FETCH_FILE (test seam: read raw statusline text from this file instead of ccstatusline).
set -u
TRIP_PCT=${TRIP_PCT:-97}
INTERVAL=${INTERVAL:-15}
WEEKLY_TRIP=${WEEKLY_TRIP:-101}   # >100 = effectively off unless set
FAIL_MAX=${FAIL_MAX:-3}

JS=$(find "$HOME/.npm/_npx" -name 'ccstatusline.js' -path '*dist*' 2>/dev/null | head -1)
STDIN='{"model":{"display_name":"x"},"workspace":{"current_dir":"'"$HOME"'"},"context_window":{"used_percentage":0}}'

fetch_raw() {                      # -> raw ccstatusline text on stdout (empty on failure)
  if [ -n "${UG_FETCH_FILE:-}" ]; then cat "$UG_FETCH_FILE" 2>/dev/null; return; fi
  # Same resolution order as the live statusline (statusline-ccwrapper.sh): prefer the
  # global install (pinned version, no network, no drift vs. what the statusline itself
  # renders) before falling back to the npx cache or a live npx fetch.
  if command -v ccstatusline >/dev/null 2>&1; then printf '%s' "$STDIN" | ccstatusline 2>/dev/null; return; fi
  if [ -n "$JS" ]; then printf '%s' "$STDIN" | node "$JS" 2>/dev/null
  else printf '%s' "$STDIN" | npx -y ccstatusline@latest 2>/dev/null; fi
}

parse_pcts() {                     # raw text on stdin -> "<session> <weekly>" (fields empty if absent)
  local raw seg_s seg_w
  raw=$(cat)
  raw=$(printf '%s' "$raw" | sed $'s/\x1b\[[0-9;]*m//g')   # strip ANSI SGR codes
  seg_s=$(printf '%s' "$raw" | grep -oE 'Session:[^%]*%' | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1)
  seg_w=$(printf '%s' "$raw" | grep -oE 'Weekly:[^%]*%'  | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1)
  printf '%s %s' "$seg_s" "$seg_w"
}

read_pcts() { fetch_raw | parse_pcts; }

ge() { [ -n "$1" ] && [ "${1%.*}" -ge "$2" ] 2>/dev/null; }   # floor($1) >= $2, false if $1 empty/NaN

# --- internal parse entrypoint (for the test suite) ---
if [ "${1:-}" = "--parse" ]; then parse_pcts; exit 0; fi

# --- one-off check ---
if [ "${1:-}" = "--once" ]; then
  read -r s w <<< "$(read_pcts)"
  if [ -z "${s:-}" ]; then
    echo "usage-guard: cannot read session usage (ccstatusline unavailable or output format changed)" >&2
    echo "Session ?%  Weekly ${w:-?}%"
    exit 2
  fi
  echo "Session ${s}%  Weekly ${w:-?}%"
  exit 0
fi

# --- guard loop ---
blind=0
first=1
while true; do
  read -r s w <<< "$(read_pcts)"
  if [ -z "${s:-}" ]; then
    if [ "$first" = 1 ]; then
      echo "USAGE-GUARD NOT ARMED: cannot read session usage (ccstatusline unavailable or output format changed). The guard would be blind — fix the reader before relying on it." >&2
      exit 2
    fi
    blind=$((blind + 1))
    if [ "$blind" -ge "$FAIL_MAX" ]; then
      echo "USAGE-GUARD WENT BLIND: session usage unreadable for ${FAIL_MAX} consecutive polls — STOP THE JOB and check the guard (it can no longer protect you)." >&2
      exit 3
    fi
    sleep "$INTERVAL"
    continue
  fi
  first=0
  blind=0
  if ge "$s" "$TRIP_PCT"; then
    echo "USAGE-GUARD TRIPPED: Session ${s}% >= ${TRIP_PCT}% — STOP THE BACKGROUND JOB NOW"
    exit 0
  fi
  if ge "$w" "$WEEKLY_TRIP"; then
    echo "USAGE-GUARD TRIPPED: Weekly ${w}% >= ${WEEKLY_TRIP}% — STOP THE BACKGROUND JOB NOW"
    exit 0
  fi
  sleep "$INTERVAL"
done
