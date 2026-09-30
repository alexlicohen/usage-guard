#!/bin/bash
# usage-guard — read or watch the live 5-hour "session" usage % (the same number the
# statusline shows), so a long background job can be stopped cleanly before the hard
# limit (e.g. Max plans with overflow disabled).
#
# SOURCES, in order:
#   1. live   — $UG_RATE_FILE (default ~/.cache/usage-guard/rate_limits.json): the
#               `rate_limits` object Claude Code passes to the statusline command on stdin,
#               written verbatim with an epoch `ts` by the statusline wrapper on every render
#               ({"ts":<epoch>,"rate_limits":{"five_hour":{"used_percentage","resets_at"},
#               "seven_day":{…}}}). If this file EXISTS it is the only source (needs jq).
#   2. ccstatusline fallback (file absent) — render ccstatusline with a synthetic stdin; it
#               fetches /api/oauth/usage itself, or serves its cache ~/.cache/ccstatusline/usage.json.
#
#   bash usage_guard.sh --once          # print "Session S%  Weekly W%  (<source>, Ns old)"; exit 0
#                                        # if fresh, exit 2 (loud, to stderr) if unreadable OR stale
#   TRIP_PCT=95 bash usage_guard.sh     # poll every INTERVAL s; exit 0 when Session >= TRIP_PCT
#                                        # (a completion notification -> stop the job)
#   printf '%s' "<raw>" | bash usage_guard.sh --parse   # internal: parse raw text (for tests)
#
# STALENESS GATE. Every reading carries an age: the live file's `ts`, or the mtime of
# ccstatusline's usage.json. Age > MAX_AGE_SEC -> `stale`; a reading whose resets_at is already
# in the past is `stale` regardless of age (its % belongs to a window that no longer exists).
# A stale number must never pass as current: ccstatusline serves its cache with NO age limit
# when it has no usable token, so without this gate a weeks-old "Session 0%" read as live.
#
# FAIL-LOUD, BUT NOT TRIGGER-HAPPY (a safety tool must never fail silent, and must never
# cry wolf — a false "STOP THE JOB" trains the operator to ignore it). Statuses:
#   * ok           — fresh reading.
#   * unavailable  — no reader (no ccstatusline / node / npx; or no jq for the live file).
#                    Persistent -> fail loud immediately (exit 2/3).
#   * nocreds      — ccstatusline rendered `[No credentials]`. Persistent -> fail loud immediately.
#   * unparseable  — rendered output with no Session:…% token and no known error token. Retried
#                    within the poll (one unlucky render must not refuse to arm a multi-hour job);
#                    still unparseable after RETRIES = a format change -> fail loud immediately.
#   * transient    — ccstatusline rendered `[Timeout]` / `[API Error]` / `[Rate limited]` /
#                    `[Parse Error]` instead of a Session %, or the live file is valid JSON
#                    without rate_limits.five_hour. Retried within the poll, then tolerated for
#                    BLIND_MAX_SEC.
#   * empty        — the reader rendered NOTHING. Transient, same handling as `transient`.
#   * stale        — see above. Not retried within a poll (it cannot heal in seconds); counts
#                    toward BLIND_MAX_SEC like empty/transient, then fails loud.
# Exit codes: 0 tripped / --once fresh read · 2 never armed (unreadable or stale at startup;
# --once on any non-ok status) · 3 went blind mid-run.
#
# Env: TRIP_PCT (default 97), INTERVAL (default 15), WEEKLY_TRIP (default 101 = off),
#      MAX_AGE_SEC (default 300 — oldest reading accepted as current),
#      BLIND_MAX_SEC (default 300 — how long empty/transient/stale is tolerated before the
#          loud exit; time-based, not poll-count-based, so it's independent of INTERVAL),
#      RETRIES (default 3 fetch attempts per poll for empty/transient/unparseable),
#      RETRY_BACKOFF (default 2 — seconds between those in-poll retries),
#      UG_RATE_FILE (live rate_limits file), UG_CCSL_CACHE (ccstatusline usage.json, whose
#          mtime ages the fallback reading),
#      UG_FETCH_FILE / UG_FETCH_CMD (test seams: raw statusline text from this file / from this
#          shell command's stdout, instead of ccstatusline).
set -u
TRIP_PCT=${TRIP_PCT:-97}
INTERVAL=${INTERVAL:-15}
WEEKLY_TRIP=${WEEKLY_TRIP:-101}   # >100 = effectively off unless set
MAX_AGE_SEC=${MAX_AGE_SEC:-300}
BLIND_MAX_SEC=${BLIND_MAX_SEC:-300}
RETRIES=${RETRIES:-3}
RETRY_BACKOFF=${RETRY_BACKOFF:-2}
RATE_FILE=${UG_RATE_FILE:-$HOME/.cache/usage-guard/rate_limits.json}
CCSL_CACHE=${UG_CCSL_CACHE:-$HOME/.cache/ccstatusline/usage.json}

JS=$(find "$HOME/.npm/_npx" -name 'ccstatusline.js' -path '*dist*' 2>/dev/null | head -1)
STDIN='{"model":{"display_name":"x"},"workspace":{"current_dir":"'"$HOME"'"},"context_window":{"used_percentage":0}}'
TRANSIENT_RE='\[(Timeout|API Error|Rate limited|Parse Error)\]'   # ccstatusline getUsageErrorMessage
NOCREDS_RE='\[No credentials\]'

now() { date +%s; }
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

mtime() {                          # epoch mtime of $1 (GNU stat, then BSD stat), fails if unknown
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || return 1
  isnum "$m" || return 1
  printf '%s' "$m"
}

fetch_raw() {                      # -> raw ccstatusline text on stdout (empty on failure)
  if [ -n "${UG_FETCH_CMD:-}" ]; then bash -c "$UG_FETCH_CMD" 2>/dev/null; return; fi
  if [ -n "${UG_FETCH_FILE:-}" ]; then cat "$UG_FETCH_FILE" 2>/dev/null; return; fi
  # Same resolution order as the live statusline wrapper: prefer the global install (pinned
  # version, no network, no drift vs. what the statusline itself renders) before falling back
  # to the npx cache or a live npx fetch.
  if command -v ccstatusline >/dev/null 2>&1; then printf '%s' "$STDIN" | ccstatusline 2>/dev/null; return; fi
  if [ -n "$JS" ]; then printf '%s' "$STDIN" | node "$JS" 2>/dev/null
  else printf '%s' "$STDIN" | npx -y ccstatusline@latest 2>/dev/null; fi
}

reader_available() {               # is the reader MECHANISM present at all? (persistent check)
  if [ -n "${UG_FETCH_CMD:-}" ]; then return 0; fi
  if [ -n "${UG_FETCH_FILE:-}" ]; then [ -r "$UG_FETCH_FILE" ]; return; fi
  command -v ccstatusline >/dev/null 2>&1 && return 0
  [ -n "$JS" ] && return 0
  command -v npx >/dev/null 2>&1 && return 0
  return 1
}

strip_ansi() { sed $'s/\x1b\[[0-9;]*m//g'; }

# One labelled segment's number: text from "<Label>:" to the FIRST following "%". The segment
# is rejected (empty) if it crosses into another label ("Session: [API Error]  Weekly: 16%"
# must not read Session as 16) or holds an error token instead of a number.
seg_pct() {                        # $1 = label, ANSI-stripped raw text on stdin
  local seg rest
  seg=$(grep -oE "$1:[^%]*%" | head -1)
  [ -z "$seg" ] && return
  rest=${seg#"$1":}
  if printf '%s' "$rest" | grep -qE '[A-Za-z][A-Za-z ]*:'; then return; fi
  if printf '%s' "$rest" | grep -qE "$TRANSIENT_RE|$NOCREDS_RE"; then return; fi
  printf '%s' "$rest" | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1
}

parse_pcts() {                     # raw text on stdin -> "<session> <weekly>" (fields empty if absent)
  local raw
  raw=$(strip_ansi)
  printf '%s %s' "$(printf '%s' "$raw" | seg_pct Session)" "$(printf '%s' "$raw" | seg_pct Weekly)"
}

# Classify a single read. Sets globals STATUS, S, W, SRC (source label), AGE (seconds, or empty)
# and WHY (human reason for any non-ok status).
STATUS=""; S=""; W=""; SRC=""; AGE=""; WHY=""

gate_age() {                       # $1 data epoch, $2/$3 session/weekly resets_at epoch (may be empty)
  local t
  t=$(now)
  AGE=$(( t - $1 ))
  if [ "$AGE" -gt "$MAX_AGE_SEC" ]; then
    STATUS=stale; WHY="reading from $SRC is ${AGE}s old (MAX_AGE_SEC=${MAX_AGE_SEC})"; return
  fi
  if isnum "$2" && [ "$2" -le "$t" ]; then
    STATUS=stale; WHY="reading from $SRC is for a 5-hour window that reset $(( t - $2 ))s ago"; return
  fi
  if isnum "$3" && [ "$3" -le "$t" ]; then
    STATUS=stale; WHY="reading from $SRC is for a weekly window that reset $(( t - $3 ))s ago"; return
  fi
  STATUS=ok
}

read_live() {
  local out ts sr wr
  SRC="live rate_limits"
  if ! command -v jq >/dev/null 2>&1; then
    STATUS=unavailable; WHY="jq not on PATH (needed to read $RATE_FILE)"; return
  fi
  out=$(jq -r '
    def f: if type == "number" then (. * 100 | round / 100 | tostring) else "" end;
    def e: if type == "number" then (floor | tostring) else "" end;
    [(.ts | e), (.rate_limits.five_hour.used_percentage | f), (.rate_limits.seven_day.used_percentage | f),
     (.rate_limits.five_hour.resets_at | e), (.rate_limits.seven_day.resets_at | e)] | join("|")
  ' "$RATE_FILE" 2>/dev/null) || { STATUS=unparseable; WHY="$RATE_FILE is not valid JSON"; return; }
  IFS='|' read -r ts S W sr wr <<EOF
$out
EOF
  # Valid JSON without a 5-hour % is a DATA condition, not a format change: another session's
  # record that carries only seven_day (seen live alternating with full records, ~20-30 s at a
  # time), or a window that just reset. Blind (retried in-poll, then BLIND_MAX_SEC), never
  # persistent — a renamed field still fails loud once the window elapses.
  if [ -z "$S" ]; then STATUS=transient; WHY="$RATE_FILE has no rate_limits.five_hour.used_percentage (a record without the 5-hour window: another session's partial write, a just-reset window, or a format change)"; return; fi
  if ! isnum "$ts"; then STATUS=stale; WHY="$RATE_FILE has no ts, so its age is unknown"; return; fi
  gate_age "$ts" "$sr" "$wr"
}

cache_reset_epoch() {              # $1 = sessionResetAt | weeklyResetAt in ccstatusline's cache -> epoch
  jq -r --arg k "$1" '.[$k] // empty | sub("\\.[0-9]+"; "") | sub("(\\+00:00|Z)$"; "Z")
                      | try fromdateiso8601 catch empty' "$CCSL_CACHE" 2>/dev/null
}

read_ccsl() {
  local raw pair m sr="" wr=""
  SRC="ccstatusline"
  raw=$(fetch_raw | strip_ansi)
  if [ -z "$raw" ]; then
    if reader_available; then STATUS=empty; WHY="reader returned empty (likely a transient /api/oauth/usage hiccup)"
    else STATUS=unavailable; WHY="reader unavailable (no ccstatusline / node / npx on PATH)"; fi
    return
  fi
  # parse_pcts emits exactly "<s> <w>" (either field possibly empty). Split on that one space
  # WITHOUT `read`, whose whitespace-collapsing would slide an absent session's weekly into S.
  pair=$(printf '%s' "$raw" | parse_pcts)
  S=${pair%% *}; W=${pair#* }
  if [ -z "$S" ]; then
    if printf '%s' "$raw" | grep -qE "$NOCREDS_RE"; then
      STATUS=nocreds; WHY="ccstatusline has no usable OAuth token ([No credentials])"
    elif printf '%s' "$raw" | grep -qE "$TRANSIENT_RE"; then
      STATUS=transient; WHY="ccstatusline usage fetch failed: $(printf '%s' "$raw" | grep -oE "$TRANSIENT_RE" | head -1)"
    else
      STATUS=unparseable; WHY="reader output has no Session: token (format changed, or the usage segment is persistently missing)"
    fi
    return
  fi
  SRC="ccstatusline cache"
  if ! m=$(mtime "$CCSL_CACHE"); then
    STATUS=stale; WHY="cannot age the ccstatusline reading ($CCSL_CACHE missing)"; return
  fi
  if command -v jq >/dev/null 2>&1; then
    sr=$(cache_reset_epoch sessionResetAt); wr=$(cache_reset_epoch weeklyResetAt)
  fi
  gate_age "$m" "$sr" "$wr"
}

classify_read() {
  S=""; W=""; AGE=""; WHY=""
  if [ -e "$RATE_FILE" ]; then read_live; else read_ccsl; fi
}

# One poll's worth of reading: retry on empty / transient / unparseable (a render without the
# usage segment, or with an error token, is usually one unlucky /api/oauth/usage fetch — seen
# live refusing to arm a multi-hour job that parsed cleanly minutes later). ok / unavailable /
# nocreds / stale are decisive on the first attempt; a genuine format change still reports
# unparseable after exhausting RETRIES.
read_poll() {
  local i
  for i in $(seq 1 "$RETRIES"); do
    classify_read
    case "$STATUS" in empty|transient|unparseable) ;; *) return ;; esac
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
    echo "Session ${S}%  Weekly ${W:-?}%  (${SRC}, ${AGE}s old)"
    exit 0
  fi
  [ "$STATUS" = unparseable ] && WHY="$WHY [after $RETRIES attempts]"
  if [ "$STATUS" = stale ]; then
    echo "usage-guard: STALE usage reading — $WHY; it said Session ${S:-?}% Weekly ${W:-?}%, which is NOT current" >&2
  else
    echo "usage-guard: cannot read session usage ($STATUS) — $WHY" >&2
  fi
  echo "Session ?%  Weekly ?%"
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

# Fail loud on a PERSISTENT unreadable class (unavailable / nocreds / unparseable). exit 2 if
# we never armed, 3 if we armed and then lost the reader.
fail_persistent() {                # $1 = human reason
  if [ "$ever_ok" = 1 ]; then
    echo "USAGE-GUARD WENT BLIND: $1 — STOP THE JOB and check the guard (it can no longer protect you)." >&2
    exit 3
  fi
  echo "USAGE-GUARD NOT ARMED: $1. The guard would be blind — fix the reader before relying on it." >&2
  exit 2
}

# Fail loud after the blind (empty / transient / stale) tolerance window has elapsed.
fail_blind() {                     # $1 = elapsed seconds
  local ctx=""
  [ -n "$last_good_s" ] && ctx=" (last good reading: Session ${last_good_s}%, ${1}s ago)"
  if [ "$ever_ok" = 1 ]; then
    echo "USAGE-GUARD WENT BLIND: no fresh reading for ${1}s (BLIND_MAX_SEC=${BLIND_MAX_SEC}); last: $STATUS — ${WHY}${ctx}. Likely a sustained API/network problem or no open statusline, not a format change. STOP THE JOB and check the guard." >&2
    exit 3
  fi
  echo "USAGE-GUARD NOT ARMED: could not establish a fresh session-usage reading within ${1}s (BLIND_MAX_SEC=${BLIND_MAX_SEC}); last: $STATUS — ${WHY}. If transient, retry; otherwise fix the reader before relying on the guard." >&2
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
    unavailable|nocreds|unparseable)
      fail_persistent "session usage unreadable ($STATUS: $WHY)"
      ;;
    *)                             # empty | transient | stale
      [ -z "$blind_since" ] && blind_since=$(now)
      elapsed=$(( $(now) - blind_since ))
      [ "$elapsed" -ge "$BLIND_MAX_SEC" ] && fail_blind "$elapsed"
      ;;
  esac
  sleep "$INTERVAL"
done
