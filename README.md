# usage-guard

[![check](https://github.com/alexlicohen/usage-guard/actions/workflows/check.yml/badge.svg)](https://github.com/alexlicohen/usage-guard/actions/workflows/check.yml)

A [Claude Code](https://claude.com/claude-code) skill: read or watch the live 5-hour
"session" usage % (the number in the statusline) and cleanly stop a long-running
background job **before** it hits the hard usage limit.

On plans where overflow is disabled, hitting the limit mid-run is a graceless hard stop
that wastes credits on a failing tail. This guard trips with headroom so you can stop the
job cleanly.

Sources, in order:

1. **Live** — `~/.cache/usage-guard/rate_limits.json`: the `rate_limits` object Claude Code
   passes to your statusline command on stdin, saved by your statusline on every render
   (see [Live source](#live-source-recommended)). These are exactly the numbers the
   statusline shows. If the file exists it is the only source.
2. **Fallback** (file absent) — [`ccstatusline`](https://www.npmjs.com/package/ccstatusline)
   rendered with a synthetic stdin; it fetches Anthropic's `/api/oauth/usage` itself, or
   serves its cache `~/.cache/ccstatusline/usage.json`.

Every reading is **aged** (the live file's `ts`, or the ccstatusline cache's mtime). A reading
older than `MAX_AGE_SEC` (default 300), or whose window's reset time has already passed, is
reported as **stale**, never as a current number. (Without this gate, ccstatusline with no
usable token serves its cache with no age limit, and a weeks-old reading passed as live.)

## One-off check

```sh
bash usage_guard.sh --once     # -> "Session 92.0%  Weekly 45.0%  (live rate_limits, 4s old)"  (exit 0)
```

Use before launching heavy work to decide whether there's headroom. Exits **2** (loud, to
stderr, naming the cause; stdout `Session ?%  Weekly ?%`) if usage can't be read **or the
reading is stale**.

## Guard a background job (the main use)

1. Launch the long job in the background.
2. Arm the guard in the background:
   ```sh
   bash usage_guard.sh            # defaults: TRIP_PCT=97, INTERVAL=15
   ```
   It polls and **exits 0 when Session ≥ TRIP_PCT**, firing a completion notification.
3. On that notification, **stop the job cleanly, then commit** (do it in that order — the
   headroom to 100% covers the round-trip). Stopping is safe only if the job is
   **resumable** (its work-list derives from on-disk state); make it resumable first.

Tune via env: `TRIP_PCT` (default 97), `INTERVAL` (default 15s), `WEEKLY_TRIP` (also trip on
the weekly window; default off), `MAX_AGE_SEC` (default 300, oldest reading accepted as
current), `BLIND_MAX_SEC` (default 300, how long a transient/stale reader is tolerated before
the loud exit), `RETRIES` / `RETRY_BACKOFF` (in-poll retries, default 3 × 2s).

## Live source (recommended)

Claude Code passes a `rate_limits` object (`five_hour` / `seven_day`, each with
`used_percentage` and epoch-seconds `resets_at`) to the statusline command on stdin. Add this
to your statusline script, after it reads stdin into `$input`:

```sh
UG_DIR="$HOME/.cache/usage-guard"
{ mkdir -p "$UG_DIR" &&
  printf '%s' "$input" | jq -ce 'select(.rate_limits != null) | {ts: (now | floor), rate_limits}' > "$UG_DIR/.rate_limits.$$" &&
  mv -f "$UG_DIR/.rate_limits.$$" "$UG_DIR/rate_limits.json"; } >/dev/null 2>&1 || rm -f "$UG_DIR/.rate_limits.$$" 2>/dev/null
```

One `jq` call (~10 ms), atomic write, errors swallowed so it can never break the render. The
file only stays fresh while a Claude Code session is open and rendering the statusline (set
`statusLine.refreshInterval` so it re-renders when idle); with no session open it ages out and
the guard reports `stale`, which is the honest answer.

## Fail-loud (why this is safe)

A usage guard that silently stops guarding, or trusts an old number, is the worst failure
mode — you'd think you're protected and blow past the limit. Each read is classified:

| Status | Cause | Response |
|---|---|---|
| `unavailable` | no reader (`ccstatusline`/`node`/`npx`, or `jq` for the live file) | persistent: fail loud now |
| `nocreds` | ccstatusline renders `[No credentials]` | persistent: fail loud now |
| `unparseable` | output has no `Session:…%` and no known error token | retried in-poll; then persistent (format change) |
| `transient` | ccstatusline renders `[Timeout]` / `[API Error]` / `[Rate limited]` / `[Parse Error]` | retried in-poll; tolerated `BLIND_MAX_SEC` |
| `empty` | reader rendered nothing | retried in-poll; tolerated `BLIND_MAX_SEC` |
| `stale` | reading older than `MAX_AGE_SEC`, or its reset time has passed | tolerated `BLIND_MAX_SEC` |

Persistent causes make the guard refuse to arm (exit **2**) or exit **3** mid-run at once;
the tolerated ones do so only after `BLIND_MAX_SEC` without a fresh reading, so a few seconds
of API flakiness can't false-stop a healthy multi-hour job. `--once` exits **2** on any non-ok
status (a one-shot can't wait out a window).

Exit codes: `0` armed-and-tripped (or `--once` fresh read) · `2` couldn't read, or stale, at
startup (and every non-ok `--once`) · `3` went blind mid-run.

## Install

```sh
git clone https://github.com/alexlicohen/usage-guard.git ~/.claude/skills/usage-guard
```

## Tests

`test/run.sh` exercises the parser and the guard logic deterministically — no ccstatusline,
no network, no GNU `timeout` (a perl watchdog; runs on macOS and Linux; needs `jq`) — via
`--parse` (pure parser) and seams: `UG_RATE_FILE` (live file), `UG_CCSL_CACHE` (the cache
whose mtime ages a fallback reading), `UG_FETCH_FILE` (raw text from a file) and
`UG_FETCH_CMD` (raw text from a command, used for retry sequences). It covers ANSI stripping,
segment anchoring (a `Session:` error never reads the `Weekly` number), format drift, error
classification, the live source, both staleness gates, the fail-loud paths and the trip
threshold. CI runs `shellcheck` + the suite.

## Notes / limits

- **Reset:** the session % is a rolling 5-hour window; it stays high until old usage ages
  out. Resuming before a reset when already high just trips again.
- **The guard only notifies — it does not kill anything itself.** You must stop the job on
  the trip.
- **Surfaces:** works on the local CLI and desktop Code tab (both render the statusline and
  can read `~/.cache`). It does not cover Claude Code cloud sessions (separate sandbox).

## License

[MIT](LICENSE) © 2026 Alexander Li Cohen
