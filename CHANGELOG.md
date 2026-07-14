# Changelog

## 1.2.0 — 2026-07-14

- **Stop crying wolf on transient API blips (safety fix).** A long, healthy guard could false-trip
  its own `WENT BLIND` / `NOT ARMED` loud exit: `ccstatusline` fetches `/api/oauth/usage` each poll
  and swallows errors, so a transient network / token-refresh hiccup emits an empty render. The old
  code counted every empty toward `FAIL_MAX` consecutive polls, so ~45s of API flakiness (3×15s)
  nuked a multi-hour job at ~10% usage, and an immediate re-arm landed in the same window and
  exited 2 with no tolerance — the worst failure for a safety tool (a false STOP trains the operator
  to ignore it). Now:
  - **Three failure modes are distinguished** (was: any empty read = "unavailable or format changed",
    a misdiagnosis that sent you chasing a format bug that didn't exist). `classify_read` splits
    fetch from parse: **unavailable** (no reader binary) and **unparseable** (rendered output, no
    `Session:` token = real format change) are persistent → still fail loud immediately;
    **empty render** is treated as transient.
  - **Transient empties are retried within the poll** (`RETRIES`, default 3; `RETRY_BACKOFF`, default 2s)
    and then **tolerated for a time-based window** (`BLIND_MAX_SEC`, default 300s) before the loud
    exit — replacing the old INTERVAL-coupled `FAIL_MAX` count. Arm-time empties enter this same
    window instead of hard-exiting 2 on the first poll (fixes the re-arm-into-flaky-window bug).
  - **Diagnostics name the actual cause** and surface the last-known-good reading; exit-code contract
    unchanged (2 = never armed, 3 = went blind mid-run).
  - **Latent parse bug fixed:** a reading with session absent but weekly present (`" 45.0"`) was
    word-split by `read -r S W`, sliding the weekly number into `S` and reading as a bogus "ok".
    Now split on the single-space separator without collapsing the empty field.
  - Env `FAIL_MAX` removed (replaced by `BLIND_MAX_SEC`); added `RETRIES`, `RETRY_BACKOFF`,
    `BLIND_MAX_SEC`. Suite grows to 19 checks (new: classification, transient tolerance, within-window
    no-bail regression, format-change-is-immediate).

## 1.1.1 — 2026-07-10

- **Fetch order fix.** `fetch_raw()` now tries the global `ccstatusline` binary first, matching
  the resolution order the live statusline wrapper (`statusline-ccwrapper.sh`) has used since the
  2026-07-02 switch to a global install. Previously the guard skipped straight to the npx cache /
  `npx -y ccstatusline@latest`, which could read a different (drifted) version than the one
  actually driving the statusline it's meant to mirror, and made the guard's fail-loud path
  depend on network reachability even when a pinned global copy was available locally.

## 1.1.0 — 2026-07-02

First public release, with a safety fix over the prior local version.

- **Fail-loud (safety fix).** Previously, if `ccstatusline` was unavailable or changed its
  output format, `read_pcts` returned empty, the trip check was always false, and the guard
  looped **forever without ever tripping** — a safety tool silently failing open. Now it
  refuses to arm at startup (exit `2`) and exits loud after `FAIL_MAX` consecutive blind
  polls mid-run (exit `3`). `--once` exits `2` when usage is unreadable.
- **Testable seams + suite.** Split fetch from parse; added `--parse` (pure parser over
  stdin) and the `UG_FETCH_FILE` raw-source seam. `test/run.sh` covers ANSI stripping,
  `Session:`/`Weekly:` anchoring, format-drift detection, the fail-loud paths, and the trip
  threshold — deterministically, no ccstatusline or network.
- **CI:** `.github/workflows/check.yml` runs `shellcheck` + the suite.
- MIT licensed; README/CHANGELOG added.
