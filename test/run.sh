#!/bin/bash
# Deterministic tests for usage_guard.sh — no ccstatusline, no network, no GNU `timeout`
# (a perl alarm watchdog keeps it portable to macOS). Exercises the pure parser (--parse), the
# live rate_limits source (UG_RATE_FILE), the ccstatusline fallback (UG_FETCH_FILE /
# UG_FETCH_CMD seams, aged by UG_CCSL_CACHE's mtime) and the guard loop. Needs jq.
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
hasnt() { case "$2" in *"$3"*) bad "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }
# Watchdog: run "$@" for at most $1 seconds. A kill by the alarm exits 142 (128+SIGALRM).
wd() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$s" "$@"; }
TIMED_OUT=142

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

# Isolation: never read the real live file or the real ccstatusline cache.
export UG_RATE_FILE="$tmp/absent-rate_limits.json"
export UG_CCSL_CACHE="$tmp/ccsl-usage.json"
echo '{}' > "$UG_CCSL_CACHE"          # fresh mtime, no reset times -> fallback readings are current
NOW=$(date +%s)

# live file writer: $1 path, $2 ts, $3 session %, $4 weekly %, $5 session resets_at, $6 weekly resets_at
live() {
  jq -nc --argjson ts "$2" --argjson s "$3" --argjson w "$4" --argjson sr "$5" --argjson wr "$6" \
    '{ts:$ts, rate_limits:{five_hour:{used_percentage:$s, resets_at:$sr}, seven_day:{used_percentage:$w, resets_at:$wr}}}' > "$1"
}

# Sequence seam: each fetch prints the next line of $tmp/seq.<name> (the last line repeats) and
# counts fetches in $tmp/seq.<name>.n.
cat > "$tmp/seq.sh" <<'EOF'
f=$1; n=$(cat "$f.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f.n"
total=$(wc -l < "$f"); [ "$n" -gt "$total" ] && n=$total
sed -n "${n}p" "$f"
EOF
seqcmd() { printf '%s\n' "${@:2}" > "$tmp/seq.$1"; rm -f "$tmp/seq.$1.n"; echo "bash $tmp/seq.sh $tmp/seq.$1"; }
seqn() { cat "$tmp/seq.$1.n" 2>/dev/null; }

GOOD=' Model: x  Ctx Used: ░░ 0.0%  Session: ▓▓░ 92.0%  Weekly: ▓▓▓ 45.0% '
LOW=' Session: ▓ 50.0%  Weekly: 45.0% '
HIGH=' Session: ▓ 98.0%  Weekly: 45.0% '
DRIFT=' Sess: 92.0%  Weekly: 45.0% '
APIERR=' Model: x  Ctx Used: 0%  [API Error]  [API Error] '
NOCRED=' Model: x  Ctx Used: 0%  [No credentials]  [No credentials] '

echo "parser:"
out=$(printf '%s' "$GOOD" | bash "$G" --parse)
eq "stripped good line -> 'session weekly'" "$out" "92.0 45.0"

ANSI=$(printf ' \x1b[38;2;1;2;3mSession:\x1b[39m ▓▓ \x1b[38;2;9;9;9m92.0\x1b[39m%%  Weekly: 45.0%% ')
out=$(printf '%s' "$ANSI" | bash "$G" --parse)
eq "ANSI-wrapped line -> strips SGR codes, parses" "$out" "92.0 45.0"

out=$(printf '%s' "$GOOD" | bash "$G" --parse | cut -d' ' -f1)
eq "Ctx 0.0% not mistaken for Session (anchoring)" "$out" "92.0"

out=$(printf '%s' "$DRIFT" | bash "$G" --parse | cut -d' ' -f1)
eq "format drift ('Sess:') -> empty session (detectable)" "$out" ""

out=$(printf '%s' ' Session: [API Error]  Weekly: 16% ' | bash "$G" --parse)
eq "Session error does not cross into Weekly's number" "$out" " 16"

out=$(printf '%s' ' Session: n/a  Weekly: 16% ' | bash "$G" --parse)
eq "Session placeholder does not cross into Weekly's label" "$out" " 16"

out=$(printf '%s' ' Session: -  Reset: 2hr  Ctx: 7% ' | bash "$G" --parse)
eq "Session placeholder does not cross into a later unrelated %" "$out" " "

out=$(printf '%s' ' Session: [████░░] 30.0%  Weekly: 45% ' | bash "$G" --parse)
eq "progress-bar brackets are not mistaken for an error" "$out" "30.0 45"

echo "--once (ccstatusline fallback, live file absent):"
printf '%s' "$GOOD" > "$tmp/good.txt"
out=$(UG_FETCH_FILE="$tmp/good.txt" bash "$G" --once); c=$?
has "--once readable -> prints Session%" "$out" "Session 92.0%"
has "--once readable -> names the fallback source" "$out" "ccstatusline cache"
ec  "--once readable -> exit 0" "$c" 0

touch -t 202601010000 "$tmp/old-cache.json"
out=$(UG_FETCH_FILE="$tmp/good.txt" UG_CCSL_CACHE="$tmp/old-cache.json" bash "$G" --once 2>&1); c=$?
has "--once fallback with an old ccstatusline cache -> STALE" "$out" "STALE"
has "--once stale -> names the age limit" "$out" "MAX_AGE_SEC=300"
has "--once stale -> stdout carries no number" "$out" "Session ?%  Weekly ?%"
ec  "--once stale -> exit 2" "$c" 2

echo '{"sessionUsage":92,"weeklyUsage":45,"weeklyResetAt":"2026-01-01T13:00:00.166407+00:00"}' > "$tmp/reset-cache.json"
out=$(UG_FETCH_FILE="$tmp/good.txt" UG_CCSL_CACHE="$tmp/reset-cache.json" bash "$G" --once 2>&1); c=$?
has "--once fallback, fresh cache but weeklyResetAt past -> STALE" "$out" "weekly window that reset"
ec  "--once past-reset fallback -> exit 2" "$c" 2

out=$(UG_FETCH_FILE="$tmp/good.txt" UG_CCSL_CACHE="$tmp/no-such-cache.json" bash "$G" --once 2>&1); c=$?
has "--once fallback with no cache file -> STALE (cannot age)" "$out" "cannot age"
ec  "--once unageable fallback -> exit 2" "$c" 2

# empty read is a distinct (transient-likely) class from a format change; --once retries then
# reports it as empty, still exit 2 (a one-shot can't wait out a transient window).
out=$(UG_FETCH_FILE=/dev/null RETRIES=1 RETRY_BACKOFF=0 bash "$G" --once 2>&1); c=$?
has "--once empty -> loud stderr" "$out" "cannot read session usage"
has "--once empty -> names the transient cause, not a format bug" "$out" "transient"
ec  "--once empty -> exit 2 (fail-loud)" "$c" 2

printf '%s' "$DRIFT" > "$tmp/drift.txt"
out=$(UG_FETCH_FILE="$tmp/drift.txt" RETRIES=1 RETRY_BACKOFF=0 bash "$G" --once 2>&1); c=$?
has "--once unparseable -> names format change" "$out" "format changed"
ec  "--once unparseable -> exit 2" "$c" 2

printf '%s' "$APIERR" > "$tmp/apierr.txt"
out=$(UG_FETCH_FILE="$tmp/apierr.txt" RETRIES=1 RETRY_BACKOFF=0 bash "$G" --once 2>&1); c=$?
has "--once [API Error] -> classified transient" "$out" "(transient)"
has "--once [API Error] -> names the token" "$out" "[API Error]"
ec  "--once transient -> exit 2" "$c" 2
for tok in 'Timeout' 'Rate limited' 'Parse Error'; do
  printf ' Ctx Used: 0%%  [%s] ' "$tok" > "$tmp/tok.txt"
  out=$(UG_FETCH_FILE="$tmp/tok.txt" RETRIES=1 RETRY_BACKOFF=0 bash "$G" --once 2>&1)
  has "--once [$tok] -> transient" "$out" "(transient)"
done

printf '%s' "$NOCRED" > "$tmp/nocred.txt"
out=$(UG_FETCH_FILE="$tmp/nocred.txt" RETRIES=1 RETRY_BACKOFF=0 bash "$G" --once 2>&1); c=$?
has "--once [No credentials] -> classified nocreds (persistent)" "$out" "(nocreds)"
ec  "--once nocreds -> exit 2" "$c" 2

echo "--once (live rate_limits file):"
live "$tmp/live.json" "$NOW" 3 80 $((NOW + 3600)) $((NOW + 86400))
out=$(UG_RATE_FILE="$tmp/live.json" UG_FETCH_FILE="$tmp/good.txt" bash "$G" --once); c=$?
has "live file -> read first (its numbers, not ccstatusline's)" "$out" "Session 3%  Weekly 80%"
has "live file -> names the source" "$out" "live rate_limits"
ec  "live file fresh -> exit 0" "$c" 0

live "$tmp/live-frac.json" "$NOW" 12.5 40 $((NOW + 3600)) $((NOW + 86400))
out=$(UG_RATE_FILE="$tmp/live-frac.json" bash "$G" --once)
has "live file fractional % preserved" "$out" "Session 12.5%"

live "$tmp/live-old.json" $((NOW - 1000)) 3 80 $((NOW + 3600)) $((NOW + 86400))
out=$(UG_RATE_FILE="$tmp/live-old.json" UG_FETCH_FILE="$tmp/good.txt" bash "$G" --once 2>&1); c=$?
has "live file older than MAX_AGE_SEC -> STALE" "$out" "STALE"
has "stale reason names the source" "$out" "live rate_limits"
hasnt "stale live file does NOT fall back to ccstatusline" "$out" "Session 92.0%"
ec  "live file stale by age -> exit 2" "$c" 2
out=$(UG_RATE_FILE="$tmp/live-old.json" MAX_AGE_SEC=2000 bash "$G" --once); c=$?
ec  "MAX_AGE_SEC is overridable" "$c" 0

live "$tmp/live-reset.json" "$NOW" 3 80 $((NOW - 10)) $((NOW + 86400))
out=$(UG_RATE_FILE="$tmp/live-reset.json" bash "$G" --once 2>&1); c=$?
has "fresh live file whose five_hour.resets_at is past -> STALE" "$out" "5-hour window that reset"
ec  "live file stale by past reset -> exit 2" "$c" 2

echo '{"ts":'"$NOW"',"rate_limits":{}}' > "$tmp/live-empty.json"
out=$(UG_RATE_FILE="$tmp/live-empty.json" RETRIES=1 bash "$G" --once 2>&1); c=$?
has "live file without five_hour -> unparseable" "$out" "(unparseable)"
ec  "live file without five_hour -> exit 2" "$c" 2

echo "retry sequences (UG_FETCH_CMD seam):"
cmd=$(seqcmd a "$DRIFT" "$GOOD")
out=$(UG_FETCH_CMD="$cmd" RETRIES=3 RETRY_BACKOFF=0 bash "$G" --once); c=$?
has "unparseable -> ok within one poll" "$out" "Session 92.0%"
ec  "unparseable -> ok exit 0" "$c" 0
eq  "unparseable -> ok took 2 fetches" "$(seqn a)" 2

cmd=$(seqcmd b "$APIERR" "$APIERR" "$GOOD")
out=$(UG_FETCH_CMD="$cmd" RETRIES=3 RETRY_BACKOFF=0 bash "$G" --once); c=$?
has "transient -> ok within one poll" "$out" "Session 92.0%"
ec  "transient -> ok exit 0" "$c" 0
eq  "transient -> ok took 3 fetches" "$(seqn b)" 3

cmd=$(seqcmd c "$NOCRED" "$GOOD")
out=$(UG_FETCH_CMD="$cmd" RETRIES=3 RETRY_BACKOFF=0 bash "$G" --once 2>&1); c=$?
has "persistent nocreds is decisive" "$out" "(nocreds)"
ec  "persistent nocreds -> exit 2" "$c" 2
eq  "persistent nocreds is NOT retried (1 fetch)" "$(seqn c)" 1

cmd=$(seqcmd d "$APIERR" "$APIERR" "$HIGH")
out=$(UG_FETCH_CMD="$cmd" RETRIES=1 RETRY_BACKOFF=0 INTERVAL=1 BLIND_MAX_SEC=3600 wd 10 bash "$G" 2>&1); c=$?
has "loop: transient across polls is tolerated, then trips on the fresh reading" "$out" "TRIPPED"
ec  "loop: transient -> ok -> trip exit 0" "$c" 0

cmd=$(seqcmd e "$LOW" "$APIERR")
out=$(UG_FETCH_CMD="$cmd" RETRIES=1 RETRY_BACKOFF=0 INTERVAL=1 BLIND_MAX_SEC=0 wd 10 bash "$G" 2>&1); c=$?
has "loop: armed then transient past the window -> WENT BLIND" "$out" "WENT BLIND"
has "loop: WENT BLIND reports last good reading" "$out" "last good reading: Session 50.0%"
ec  "loop: went blind -> exit 3" "$c" 3

echo "guard loop:"
# Transient-empty at startup is TOLERATED for BLIND_MAX_SEC, then exits 2 "never armed" — it does
# NOT hard-exit 2 on the first empty poll (that was the false-positive re-arm bug). BLIND_MAX_SEC=0
# collapses the window so the loud exit is immediate and deterministic here.
out=$(UG_FETCH_FILE=/dev/null BLIND_MAX_SEC=0 RETRIES=1 RETRY_BACKOFF=0 INTERVAL=1 wd 10 bash "$G" 2>&1); c=$?
has "transient-empty at startup -> NOT ARMED after window" "$out" "NOT ARMED"
has "transient-empty message names transient cause" "$out" "transient"
ec  "transient-empty at startup -> exit 2" "$c" 2

# A tolerance window > 0 must NOT bail on the very first empty poll (regression guard for the bug).
UG_FETCH_FILE=/dev/null BLIND_MAX_SEC=3600 RETRIES=1 RETRY_BACKOFF=0 INTERVAL=1 wd 2 bash "$G" >/dev/null 2>&1; c=$?
ec "empty within window -> keeps guarding (timed out, not bailed)" "$c" "$TIMED_OUT"

# Stale is blind, not persistent: tolerated within the window, loud after it.
UG_RATE_FILE="$tmp/live-old.json" BLIND_MAX_SEC=3600 INTERVAL=1 wd 2 bash "$G" >/dev/null 2>&1; c=$?
ec "stale within window -> keeps guarding (timed out, not bailed)" "$c" "$TIMED_OUT"
out=$(UG_RATE_FILE="$tmp/live-old.json" BLIND_MAX_SEC=0 INTERVAL=1 wd 10 bash "$G" 2>&1); c=$?
has "stale past window at startup -> NOT ARMED" "$out" "NOT ARMED"
has "stale NOT ARMED names stale" "$out" "last: stale"
ec  "stale past window at startup -> exit 2" "$c" 2

# Persistent classes fail loud immediately (no waiting out the window).
out=$(UG_FETCH_FILE="$tmp/drift.txt" BLIND_MAX_SEC=3600 RETRY_BACKOFF=0 INTERVAL=1 wd 10 bash "$G" 2>&1); c=$?
has "startup format-change -> refuses to arm immediately" "$out" "NOT ARMED"
has "startup format-change -> names format change" "$out" "format changed"
ec  "startup format-change -> exit 2 (no wait)" "$c" 2

out=$(UG_FETCH_FILE="$tmp/nocred.txt" BLIND_MAX_SEC=3600 INTERVAL=1 wd 10 bash "$G" 2>&1); c=$?
has "startup nocreds -> refuses to arm immediately" "$out" "NOT ARMED"
ec  "startup nocreds -> exit 2 (no wait)" "$c" 2

printf '%s' "$HIGH" > "$tmp/high.txt"
out=$(UG_FETCH_FILE="$tmp/high.txt" TRIP_PCT=97 INTERVAL=1 wd 10 bash "$G"); c=$?
has "Session >= TRIP_PCT -> TRIPPED" "$out" "TRIPPED"
ec  "Session >= TRIP_PCT -> exit 0" "$c" 0

live "$tmp/live-high.json" "$NOW" 98 80 $((NOW + 3600)) $((NOW + 86400))
out=$(UG_RATE_FILE="$tmp/live-high.json" TRIP_PCT=97 INTERVAL=1 wd 10 bash "$G"); c=$?
has "live Session >= TRIP_PCT -> TRIPPED" "$out" "Session 98%"
ec  "live trip -> exit 0" "$c" 0

printf '%s' "$LOW" > "$tmp/low.txt"
out=$(UG_FETCH_FILE="$tmp/low.txt" TRIP_PCT=97 INTERVAL=1 wd 2 bash "$G"); c=$?
hasnt "below TRIP_PCT does not trip" "$out" "TRIPPED"
ec  "below TRIP_PCT keeps guarding (timed out)" "$c" "$TIMED_OUT"

echo ""
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
