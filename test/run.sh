#!/bin/bash
# Deterministic tests for usage_guard.sh — no ccstatusline, no network.
# Exercises the pure parser (--parse) and the guard logic via the UG_FETCH_FILE seam.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
G="$DIR/usage_guard.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  ok   - $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL - $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }
ec()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (exit $2 want $3)"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }

echo "parser:"
STRIPPED=' Model: x  Ctx Used: ░░ 0.0%  Session: ▓▓░ 92.0%  Weekly: ▓▓▓ 45.0% '
out=$(printf '%s' "$STRIPPED" | bash "$G" --parse)
eq "stripped good line -> 'session weekly'" "$out" "92.0 45.0"

ANSI=$(printf ' \x1b[38;2;1;2;3mSession:\x1b[39m ▓▓ \x1b[38;2;9;9;9m92.0\x1b[39m%%  Weekly: 45.0%% ')
out=$(printf '%s' "$ANSI" | bash "$G" --parse)
eq "ANSI-wrapped line -> strips SGR codes, parses" "$out" "92.0 45.0"

out=$(printf '%s' "$STRIPPED" | bash "$G" --parse | cut -d' ' -f1)
eq "Ctx 0.0% not mistaken for Session (anchoring)" "$out" "92.0"

DRIFT=' Sess: 92.0%  Weekly: 45.0% '
out=$(printf '%s' "$DRIFT" | bash "$G" --parse | cut -d' ' -f1)
eq "format drift ('Sess:') -> empty session (detectable)" "$out" ""

echo "--once:"
printf '%s' "$STRIPPED" > "$tmp/good.txt"
out=$(UG_FETCH_FILE="$tmp/good.txt" bash "$G" --once); c=$?
has "--once readable -> prints Session%" "$out" "Session 92.0%"
ec  "--once readable -> exit 0" "$c" 0

# empty read is a distinct (transient-likely) class from a format change; --once retries then
# reports it as empty, still exit 2 (a one-shot can't wait out a transient window).
out=$(UG_FETCH_FILE=/dev/null RETRIES=1 RETRY_BACKOFF=0 bash "$G" --once 2>&1); c=$?
has "--once empty -> loud stderr" "$out" "cannot read session usage"
has "--once empty -> names the transient cause, not a format bug" "$out" "transient"
ec  "--once empty -> exit 2 (fail-loud)" "$c" 2

# a genuine format change (rendered output, no Session: token) is reported as such, not as empty.
printf '%s' "$DRIFT" > "$tmp/drift.txt"
out=$(UG_FETCH_FILE="$tmp/drift.txt" RETRIES=1 RETRY_BACKOFF=0 bash "$G" --once 2>&1); c=$?
has "--once unparseable -> names format change" "$out" "format changed"
ec  "--once unparseable -> exit 2" "$c" 2

echo "guard loop:"
# Transient-empty at startup is TOLERATED for BLIND_MAX_SEC, then exits 2 "never armed" — it does
# NOT hard-exit 2 on the first empty poll (that was the false-positive re-arm bug). BLIND_MAX_SEC=0
# collapses the window so the loud exit is immediate and deterministic here.
out=$(UG_FETCH_FILE=/dev/null BLIND_MAX_SEC=0 RETRIES=1 RETRY_BACKOFF=0 INTERVAL=1 bash "$G" 2>&1); c=$?
has "transient-empty at startup -> NOT ARMED after window" "$out" "NOT ARMED"
has "transient-empty message names transient cause" "$out" "transient"
ec  "transient-empty at startup -> exit 2" "$c" 2

# A tolerance window > 0 must NOT bail on the very first empty poll (regression guard for the bug).
if command -v timeout >/dev/null 2>&1; then
  UG_FETCH_FILE=/dev/null BLIND_MAX_SEC=3600 RETRIES=1 RETRY_BACKOFF=0 INTERVAL=1 timeout 2 bash "$G" >/dev/null 2>&1; c=$?
  ec "empty within window -> keeps guarding (timed out, not bailed)" "$c" 124
else
  echo "  skip - within-window tolerance (no 'timeout' on this host)"
fi

# A format change mid-poll is persistent -> fail loud immediately (no waiting out the window).
out=$(UG_FETCH_FILE="$tmp/drift.txt" BLIND_MAX_SEC=3600 INTERVAL=1 bash "$G" 2>&1); c=$?
has "startup format-change -> refuses to arm immediately" "$out" "NOT ARMED"
has "startup format-change -> names format change" "$out" "format changed"
ec  "startup format-change -> exit 2 (no wait)" "$c" 2

printf ' Session: ▓ 98.0%%  Weekly: 45.0%% ' > "$tmp/high.txt"
out=$(UG_FETCH_FILE="$tmp/high.txt" TRIP_PCT=97 INTERVAL=1 bash "$G"); c=$?
has "Session >= TRIP_PCT -> TRIPPED" "$out" "TRIPPED"
ec  "Session >= TRIP_PCT -> exit 0" "$c" 0

printf ' Session: ▓ 50.0%%  Weekly: 45.0%% ' > "$tmp/low.txt"
if command -v timeout >/dev/null 2>&1; then
  out=$(UG_FETCH_FILE="$tmp/low.txt" TRIP_PCT=97 INTERVAL=1 timeout 2 bash "$G")
  case "$out" in *TRIPPED*) bad "below TRIP_PCT must NOT trip" ;; *) ok "below TRIP_PCT does not trip" ;; esac
else
  echo "  skip - below-threshold no-trip (no 'timeout' on this host)"
fi

echo ""
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
