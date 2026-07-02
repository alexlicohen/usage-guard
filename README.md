# usage-guard

[![check](https://github.com/alexlicohen/usage-guard/actions/workflows/check.yml/badge.svg)](https://github.com/alexlicohen/usage-guard/actions/workflows/check.yml)

A [Claude Code](https://claude.com/claude-code) skill: read or watch the live 5-hour
"session" usage % (the number in the statusline) and cleanly stop a long-running
background job **before** it hits the hard usage limit.

On plans where overflow is disabled, hitting the limit mid-run is a graceless hard stop
that wastes credits on a failing tail. This guard trips with headroom so you can stop the
job cleanly.

Source of truth: [`ccstatusline`](https://www.npmjs.com/package/ccstatusline), which fetches
Anthropic's `/api/oauth/usage`. The number matches the statusline's "Session" slider.

## One-off check

```sh
bash usage_guard.sh --once     # -> "Session 92.0%  Weekly 45.0%"  (exit 0)
```

Use before launching heavy work to decide whether there's headroom. Exits **2** (loud, to
stderr) if usage can't be read.

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
the weekly window; default off), `FAIL_MAX` (consecutive blind polls before a loud exit).

## Fail-loud (why this is safe)

A usage guard that silently stops guarding is the worst failure mode — you'd think you're
protected and blow past the limit. So if the underlying reader is unavailable or
ccstatusline changes its output format:

- **at startup** the guard refuses to arm — exit **2**, message on stderr — instead of
  entering a loop that can never trip;
- **mid-run** it exits **3** after `FAIL_MAX` consecutive unreadable polls rather than
  looping blind.

Exit codes: `0` armed-and-tripped (or `--once` read OK) · `2` couldn't read at startup ·
`3` went blind mid-run.

## Install

```sh
git clone https://github.com/alexlicohen/usage-guard.git ~/.claude/skills/usage-guard
```

## Tests

`test/run.sh` exercises the parser and the guard logic deterministically — no ccstatusline,
no network — via `--parse` (pure parser) and the `UG_FETCH_FILE` seam (feed raw text from a
file). It covers ANSI stripping, `Session:`/`Weekly:` anchoring, **format-drift detection**,
the fail-loud paths, and the trip threshold. CI runs `shellcheck` + the suite.

## Notes / limits

- **Reset:** the session % is a rolling 5-hour window; it stays high until old usage ages
  out. Resuming before a reset when already high just trips again.
- **The guard only notifies — it does not kill anything itself.** You must stop the job on
  the trip.
- **Surfaces:** works wherever a local `ccstatusline` is reachable (CLI, desktop Code tab).
  It does not cover Claude Code cloud sessions (separate sandbox; no local creds).

## License

[MIT](LICENSE) © 2026 Alexander Li Cohen
