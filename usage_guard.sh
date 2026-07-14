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
# FAIL-LOUD, BUT NOT TRIGGER-HAPPY (a safety tool must never fail silent, and must never
# cry wolf — a false "STOP THE JOB" trains the operator to ignore it). Three failure modes
# are distinguished, because they need opposite responses:
#   * unavailable  — the reader binary is genuinely absent (no ccstatusline / node / npx).
#                    Persistent, won't self-heal -> fail loud immediately (exit 2/3).
#   * unparseable  — the reader rendered output but it has no "Session:…%" token.
#                    A real format change; persistent -> fail loud immediately (exit 2/3).
#   * empty        — the reader rendered NOTHING. ccstatusline fetches /api/oauth/usage per
#                    poll and swallows errors, so a transient network / token-refresh hiccup
#                    emits no output. This is almost always transient -> retry within the
#                    poll, then tolerate for up to BLIND_MAX_SEC before going loud, rather
#                    than nuking a healthy multi-hour job over a few seconds of API flakiness.
# Exit codes: 0 tripped / read OK · 2 never armed (unreadable at startup) · 3 went blind mid-run.
#
# Env: TRIP_PCT (default 97), INTERVAL (default 15), WEEKLY_TRIP (default 101 = off),
#      BLIND_MAX_SEC (default 300 — how long a transient-empty reader is tolerated before
#          the loud exit; time-based, not poll-count-based, so it's independent of INTERVAL),
#      RETRIES (default 3 fetch attempts per poll before an empty read counts as blind),
#      RETRY_BACKOFF (default 2 — seconds between those in-poll retries),
#      UG_FETCH_FILE (test seam: read raw statusline text from this file instead of ccstatusline).
set -u
TRIP_PCT=${TRIP_PCT:-97}
INTERVAL=${INTERVAL:-15}
WEEKLY_TRIP=${WEEKLY_TRIP:-101}   # >100 = effectively off unless set
BLIND_MAX_SEC=${BLIND_MAX_SEC:-300}
RETRIES=${RETRIES:-3}
RETRY_BACKOFF=${RETRY_BACKOFF:-2}

JS=$(find "$HOME/.npm/_npx" -name 'ccstatusline.js' -path '*dist*' 2>/dev/null | head -1)
STDIN='{"model":{"display_name":"x"},"workspace":{"current_dir":"'"$HOME"'"},"context_window":{"used_percentage":0}}'

now() { date +%s; }

fetch_raw() {                      # -> raw ccstatusline text on stdout (empty on failure)
  if [ -n "${UG_FETCH_FILE:-}" ]; then cat "$UG_FETCH_FILE" 2>/dev/null; return; fi
  # Same resolution order as the live statusline (statusline-ccwrapper.sh): prefer the
  # global install (pinned version, no network, no drift vs. what the statusline itself
  # renders) before falling back to the npx cache or a live npx fetch.
  if command -v ccstatusline >/dev/null 2>&1; then printf '%s' "$STDIN" | ccstatusline 2>/dev/null; return; fi
  if [ -n "$JS" ]; then printf '%s' "$STDIN" | node "$JS" 2>/dev/null
  else printf '%s' "$STDIN" | npx -y ccstatusline@latest 2>/dev/null; fi
}

reader_available() {               # is the reader MECHANISM present at all? (persistent check)
  if [ -n "${UG_FETCH_FILE:-}" ]; then [ -r "$UG_FETCH_FILE" ]; return; fi
  command -v ccstatusline >/dev/null 2>&1 && return 0
  [ -n "$JS" ] && return 0
  command -v npx >/dev/null 2>&1 && return 0
  return 1
}

parse_pcts() {                     # raw text on stdin -> "<session> <weekly>" (fields empty if absent)
  local raw seg_s seg_w
  raw=$(cat)
  raw=$(printf '%s' "$raw" | sed $'s/\x1b\[[0-9;]*m//g')   # strip ANSI SGR codes
  seg_s=$(printf '%s' "$raw" | grep -oE 'Session:[^%]*%' | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1)
  seg_w=$(printf '%s' "$raw" | grep -oE 'Weekly:[^%]*%'  | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1)
  printf '%s %s' "$seg_s" "$seg_w"
}

# Classify a single read. Sets globals STATUS (ok|empty|unparseable|unavailable), S, W.
# Splitting fetch from parse is what lets us tell a transient empty render (retryable) apart
# from a genuine format change (rendered text, no Session: token -> persistent).
STATUS=""; S=""; W=""
classify_read() {
  local raw pair
  raw=$(fetch_raw)
  S=""; W=""
  if [ -n "$raw" ]; then
    # parse_pcts emits exactly "<s> <w>" (single-space separated, either field possibly empty).
    # Split on that one space WITHOUT `read`, whose whitespace-collapsing would drop an empty
    # session field and slide the weekly value into S (session missing + weekly present would
    # then read as a bogus "ok" with weekly's number in S).
    pair=$(printf '%s' "$raw" | parse_pcts)
    S=${pair%% *}; W=${pair#* }
    if [ -n "$S" ]; then STATUS=ok; else STATUS=unparseable; fi
    return
  fi
  if reader_available; then STATUS=empty; else STATUS=unavailable; fi
}

# One poll's worth of reading: retry ONLY on 'empty' (the transient class); ok/unparseable/
# unavailable are decisive on the first attempt. Absorbs a single flaky /api/oauth/usage fetch
# without it ever counting toward the blind window.
read_poll() {
  local i
  for i in $(seq 1 "$RETRIES"); do
    classify_read
    [ "$STATUS" = empty ] || return
    [ "$i" -lt "$RETRIES" ] && [ "$RETRY_BACKOFF" -gt 0 ] 2>/dev/null && sleep "$RETRY_BACKOFF"
  done
}

ge() { [ -n "$1" ] && [ "${1%.*}" -ge "$2" ] 2>/dev/null; }   # floor($1) >= $2, false if $1 empty/NaN

# --- internal parse entrypoint (for the test suite) ---
if [ "${1:-}" = "--parse" ]; then parse_pcts; exit 0; fi

# --- one-off check ---
if [ "${1:-}" = "--once" ]; then
  read_poll
  if [ "$STATUS" = ok ]; then
    echo "Session ${S}%  Weekly ${W:-?}%"
    exit 0
  fi
  case "$STATUS" in
    unavailable) reason="reader unavailable (no ccstatusline / node / npx on PATH)" ;;
    unparseable) reason="reader output has no Session: token (format changed)" ;;
    *)           reason="reader returned empty (likely a transient /api/oauth/usage hiccup — try again)" ;;
  esac
  echo "usage-guard: cannot read session usage — $reason" >&2
  echo "Session ?%  Weekly ${W:-?}%"
  exit 2
fi

# --- guard loop ---
# ever_ok:      did we ever establish a good reading? (decides exit 2 "never armed" vs 3 "went blind")
# blind_since:  epoch of the first consecutive blind poll (cleared on every ok); the tolerance
#               window is time-based (now - blind_since >= BLIND_MAX_SEC), so a burst of API
#               flakiness lasting seconds cannot end a multi-hour guard.
# last_good_s:  last-known-good Session %, surfaced in the loud message so the operator sees the
#               guard was healthy moments ago (not chasing a phantom format bug).
ever_ok=0
blind_since=""
last_good_s=""

# Fail loud on a PERSISTENT unreadable class (unavailable / unparseable). exit 2 if we never
# armed, 3 if we armed and then lost the reader.
fail_persistent() {                # $1 = human reason
  if [ "$ever_ok" = 1 ]; then
    echo "USAGE-GUARD WENT BLIND: $1 — STOP THE JOB and check the guard (it can no longer protect you)." >&2
    exit 3
  fi
  echo "USAGE-GUARD NOT ARMED: $1. The guard would be blind — fix the reader before relying on it." >&2
  exit 2
}

# Fail loud after the transient-empty tolerance window has elapsed.
fail_blind() {                     # $1 = elapsed seconds
  local ctx=""
  [ -n "$last_good_s" ] && ctx=" (last good reading: Session ${last_good_s}%, ${1}s ago)"
  if [ "$ever_ok" = 1 ]; then
    echo "USAGE-GUARD WENT BLIND: reader returned empty for ${1}s (BLIND_MAX_SEC=${BLIND_MAX_SEC}) — likely a sustained API/network problem, not a format change${ctx}. STOP THE JOB and check the guard." >&2
    exit 3
  fi
  echo "USAGE-GUARD NOT ARMED: could not establish a session-usage reading within ${1}s (reader returned empty; BLIND_MAX_SEC=${BLIND_MAX_SEC}). Likely a transient API/network problem — retry, or fix the reader before relying on the guard." >&2
  exit 2
}

while true; do
  read_poll
  case "$STATUS" in
    ok)
      ever_ok=1
      blind_since=""
      last_good_s=$S
      if ge "$S" "$TRIP_PCT"; then
        echo "USAGE-GUARD TRIPPED: Session ${S}% >= ${TRIP_PCT}% — STOP THE BACKGROUND JOB NOW"
        exit 0
      fi
      if ge "$W" "$WEEKLY_TRIP"; then
        echo "USAGE-GUARD TRIPPED: Weekly ${W}% >= ${WEEKLY_TRIP}% — STOP THE BACKGROUND JOB NOW"
        exit 0
      fi
      ;;
    unavailable)
      fail_persistent "session usage unreadable (reader unavailable: no ccstatusline / node / npx)"
      ;;
    unparseable)
      fail_persistent "session usage unparseable (reader rendered output but no Session: token — output format changed)"
      ;;
    empty)
      [ -z "$blind_since" ] && blind_since=$(now)
      elapsed=$(( $(now) - blind_since ))
      [ "$elapsed" -ge "$BLIND_MAX_SEC" ] && fail_blind "$elapsed"
      ;;
  esac
  sleep "$INTERVAL"
done
