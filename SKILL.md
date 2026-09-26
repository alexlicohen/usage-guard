---
name: usage-guard
description: Read or watch the live 5-hour "session" usage % (the number in the statusline) and cleanly stop a long-running background job before it hits the hard usage limit. Use when launching or supervising a long autonomous background job (a Workflow, a big batch of Task agents, a long render/build loop) — especially on Max plans where overflow is disabled and hitting the limit is a graceless hard stop. Triggers: "guard the usage", "stop before the limit", "watch my 5h usage", "don't blow past my credits", or any time you start a multi-hour background job and want a safety net.
---

# usage-guard

A long autonomous job (Workflow / fan-out of Task agents) can burn through the 5-hour
usage window and hit the limit mid-run — which, with overflow disabled, is a hard stop
that wastes credits on a graceless failing tail. This skill reads the **exact** session
usage % shown in the statusline and trips so you can stop the job cleanly, with headroom.

Sources, in order: (1) **live** — `~/.cache/usage-guard/rate_limits.json`, the `rate_limits`
object Claude Code passes to the statusline command, saved on every render by the statusline
script (snippet in README › Live source); if the file exists it is the only source; (2)
**fallback** — `ccstatusline` rendered with a synthetic stdin (fetches `/api/oauth/usage`, or
serves its cache `~/.cache/ccstatusline/usage.json`). Every reading is aged; older than
`MAX_AGE_SEC` (default 300) or past its window's reset time = **stale**, never a number.

## One-off check

```bash
bash ~/.claude/skills/usage-guard/usage_guard.sh --once
# -> "Session 92.0%  Weekly 45.0%  (live rate_limits, 4s old)"          exit 0
# -> stderr "usage-guard: STALE usage reading — …", stdout "Session ?%  Weekly ?%"   exit 2
```
Use before launching heavy work to decide whether there's headroom. Exit 2 means there is
**no current number** (unreadable or stale; stderr names the cause and age): don't treat it
as 0%. With no Claude Code session open to render the statusline, expect `stale`.

## Guard a background job (the main use)

1. Launch the long job in the background (a `Workflow`, or a batch you control).
2. **Arm the guard in the background** (Bash `run_in_background: true`):
   ```bash
   bash ~/.claude/skills/usage-guard/usage_guard.sh        # defaults: TRIP_PCT=97, INTERVAL=15
   ```
   It polls every 15s and **exits when Session ≥ TRIP_PCT**, which fires a completion
   notification back to you. On the trip, **`TaskStop` the job immediately; commit afterward**
   (the data is already safe on disk, so the commit is off the critical path).
3. **On that notification, stop the job cleanly** — `TaskStop` the workflow (or stop your
   batch). Then checkpoint/commit. Stopping is safe **only if the job is resumable**
   (work-list derived from on-disk state); make the job resumable before relying on this.

Tune: `TRIP_PCT` (default 97 — lower to 95 to widen the round-trip margin for fast-burning
jobs), `INTERVAL` (default 15s), `WEEKLY_TRIP` (also trip on the weekly window),
`MAX_AGE_SEC` (default 300 — oldest reading accepted as current), `BLIND_MAX_SEC` (default
300 — how long a transient / empty / stale reader is tolerated before the loud exit). The 15s poll + "stop now, commit later" keeps 97% safe even at heavy burn.

## Notes / limits

- **Fail-loud, but not trigger-happy (a safety tool must never fail silent — and must never
  cry wolf).** Each read gets a status, and the responses differ:
  - **unavailable** (no `ccstatusline`/`node`/`npx`, or no `jq` for the live file) and
    **nocreds** (ccstatusline renders `[No credentials]`) — persistent → **fail loud
    immediately** (refuses to arm, exit 2; or exits 3 mid-run).
  - **unparseable** (output rendered, no `Session:…%` and no known error token) — retried
    within the poll (one unlucky render must not refuse to arm a long job); still unparseable
    after `RETRIES` = a format change → fail loud immediately.
  - **transient** (ccstatusline renders `[Timeout]` / `[API Error]` / `[Rate limited]` /
    `[Parse Error]`) and **empty** (renders nothing) — retried within the poll (`RETRIES`×,
    `RETRY_BACKOFF` apart), then **tolerated for up to `BLIND_MAX_SEC`** before going loud.
  - **stale** (reading older than `MAX_AGE_SEC`, or its reset time already passed) — not
    retried in-poll (can't heal in seconds); tolerated for `BLIND_MAX_SEC` like transient.
  The parser never crosses segments: `Session: [API Error]  Weekly: 16%` reads Session as
  unknown, not 16.

  If you see `NOT ARMED` / `WENT BLIND`, read the message — it names the status and cause and
  reports the last-known-good reading. `--once` exits 2 on any non-ok read (a one-shot can't
  wait out a window). Exit codes: `0` tripped / fresh read · `2` never armed (unreadable or
  stale at startup; any non-ok `--once`) · `3` went blind mid-run.
- **Reset:** the session % is the rolling 5-hour window; it stays high until old usage
  ages out. After a reset, headroom returns. Resuming *before* a reset when already high
  just trips again immediately.
- **The guard only notifies — it does not kill anything itself.** You must `TaskStop` the
  job on the trip (the 5% headroom to 100% covers that round-trip; at 95% you are not yet
  rate-limited, so you can still act).
- **Surfaces:** works on the local CLI and the desktop app's Code tab (both read
  `~/.claude/` and `~/.cache/`). The live file is fresh only while a session renders the
  statusline (`statusLine.refreshInterval` keeps it fresh when idle). It does **not** cover
  Claude Code cloud sessions (separate sandbox; no local `npx ccstatusline` / creds). For a repo you run in the cloud, commit a project-level
  `.claude/skills/usage-guard/` and verify the reader works there.
- A fully-automatic *pre-flight block* is wired as a `PreToolUse` hook on `Workflow`
  (`~/.claude/hooks/usage-preflight.sh`, asks at ≥90% session usage, fail-open).
- **Deferred (not built):** auto-resume-on-reset — a local launchd/cron timer that re-launches a
  guarded resume after the 5h window rolls over. Design: one-shot per trip, weekly-% capped,
  notify-on-fire (unattended multi-window resume can burn the weekly limit).
