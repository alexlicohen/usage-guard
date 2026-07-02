---
name: usage-guard
description: Read or watch the live 5-hour "session" usage % (the number in the statusline) and cleanly stop a long-running background job before it hits the hard usage limit. Use when launching or supervising a long autonomous background job (a Workflow, a big batch of Task agents, a long render/build loop) — especially on Max plans where overflow is disabled and hitting the limit is a graceless hard stop. Triggers: "guard the usage", "stop before the limit", "watch my 5h usage", "don't blow past my credits", or any time you start a multi-hour background job and want a safety net.
---

# usage-guard

A long autonomous job (Workflow / fan-out of Task agents) can burn through the 5-hour
usage window and hit the limit mid-run — which, with overflow disabled, is a hard stop
that wastes credits on a graceless failing tail. This skill reads the **exact** session
usage % shown in the statusline and trips so you can stop the job cleanly, with headroom.

Source of truth: `ccstatusline` (which fetches Anthropic's `/api/oauth/usage`). The number
matches the statusline's "Session" slider.

## One-off check

```bash
bash ~/.claude/skills/usage-guard/usage_guard.sh --once     # -> "Session 92.0%  Weekly 45.0%"
```
Use before launching heavy work to decide whether there's headroom.

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
jobs), `INTERVAL` (default 15s), `WEEKLY_TRIP` (also trip on the weekly window). The 15s poll
+ "stop now, commit later" keeps 97% safe even at heavy burn.

## Notes / limits

- **Fail-loud (a safety tool must never fail silent):** if ccstatusline is unavailable or
  changes its output format, the reader returns empty. The guard then **refuses to arm at
  startup (exit 2)** and **exits loud after `FAIL_MAX` consecutive blind polls (exit 3)**,
  rather than looping forever pretending to protect you. `--once` exits 2 when usage is
  unreadable. If you see `NOT ARMED` / `WENT BLIND`, fix the reader — do not trust the guard.
  Exit codes: `0` tripped / read OK · `2` unreadable at startup · `3` went blind mid-run.
- **Reset:** the session % is the rolling 5-hour window; it stays high until old usage
  ages out. After a reset, headroom returns. Resuming *before* a reset when already high
  just trips again immediately.
- **The guard only notifies — it does not kill anything itself.** You must `TaskStop` the
  job on the trip (the 5% headroom to 100% covers that round-trip; at 95% you are not yet
  rate-limited, so you can still act).
- **Surfaces:** works on the local CLI and the desktop app's Code tab (both read
  `~/.claude/`). It does **not** cover Claude Code cloud sessions (separate sandbox; no
  local `npx ccstatusline` / creds). For a repo you run in the cloud, commit a project-level
  `.claude/skills/usage-guard/` and verify the reader works there.
- A fully-automatic *pre-flight block* is wired as a `PreToolUse` hook on `Workflow`
  (`~/.claude/hooks/usage-preflight.sh`, asks at ≥90% session usage, fail-open).
- **Deferred (not built):** auto-resume-on-reset — a local launchd/cron timer that re-launches a
  guarded resume after the 5h window rolls over. Design: one-shot per trip, weekly-% capped,
  notify-on-fire (unattended multi-window resume can burn the weekly limit).
