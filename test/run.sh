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

out=$(UG_FETCH_FILE=/dev/null bash "$G" --once 2>&1); c=$?
has "--once unreadable -> loud stderr" "$out" "cannot read session usage"
ec  "--once unreadable -> exit 2 (fail-loud)" "$c" 2

echo "guard loop:"
out=$(UG_FETCH_FILE=/dev/null INTERVAL=1 bash "$G" 2>&1); c=$?
has "startup unreadable -> refuses to arm" "$out" "NOT ARMED"
ec  "startup unreadable -> exit 2 (no blind loop)" "$c" 2

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
