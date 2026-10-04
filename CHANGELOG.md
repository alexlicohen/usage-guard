# Changelog

## 1.3.2 — 2026-10-04

- SKILL.md description is a folded block scalar (strict YAML rejected the bare `Triggers: "…"`) and names `--once`'s Weekly % (read by triage rule 5 and bake-off pauses).

## 1.3.1 — 2026-09-30

- **Partial live records no longer kill the guard.** Several sessions render the statusline at
  once and write the same file (last writer wins); some pass a `rate_limits` holding only
  `seven_day` (with a different weekly %), which held the file for 20–30 s at a time. The guard
  classified a record without `five_hour` as `unparseable` (persistent) and exited 3 minutes
  after arming, with usage fine. Fixes:
  - **Guard:** valid JSON without `rate_limits.five_hour.used_percentage` is now `transient`
    (retried in-poll, then tolerated for `BLIND_MAX_SEC`); a renamed field still goes loud once
    the window elapses. Invalid JSON stays `unparseable`.
  - **Writer (README snippet):** writes only records whose `five_hour.used_percentage` is a
    number, so a partial record can never overwrite a full one.
  - Tests: seven_day-only record, invalid JSON, and a guard loop over alternating full /
    partial records (rides it out; still exits 3 past `BLIND_MAX_SEC`). 86 checks.

## 1.3.0 — 2026-09-26

- **Stop trusting stale numbers (safety fix).** `--once` had printed the same reading for two
  weeks. The guard renders ccstatusline with a synthetic stdin that has no `rate_limits`, so
  ccstatusline fetches `/api/oauth/usage` itself; with no usable token it serves its cache
  `~/.cache/ccstatusline/usage.json` with no age limit, and the guard took that as live.
  - **Live source first.** The statusline script saves Claude Code's stdin `rate_limits`
    (verbatim, plus an epoch `ts`) to `~/.cache/usage-guard/rate_limits.json` on every render
    (one `jq` call, atomic, errors swallowed; snippet in README). If that file exists it is the
    only source (`jq` required); ccstatusline is the fallback only when it is absent.
  - **Staleness gate.** Every reading carries an age (the file's `ts`, or the ccstatusline
    cache's mtime). Older than `MAX_AGE_SEC` (default 300), a missing cache, or a `resets_at`
    already in the past → new status `stale`. `--once` reports it loudly (stderr names source,
    age and the stale numbers; stdout `Session ?%  Weekly ?%`) and exits 2; the loop treats it
    like a blind reading (counts toward `BLIND_MAX_SEC`, not retried in-poll).
  - `--once` success output gains the source and age: `Session 5%  Weekly 81%  (live rate_limits, 1s old)`.
- **Error renders classified.** ccstatusline renders `[Timeout]` / `[API Error]` /
  `[Rate limited]` / `[Parse Error]` in place of a failed usage segment → `transient` (retried
  in-poll, then the blind window); `[No credentials]` → `nocreds` (persistent, fail loud
  immediately). `unparseable` (no Session token, no error token) is now retried in-poll before
  it counts as a format change: one render without the usage segment had refused to arm a
  multi-hour job that parsed cleanly minutes later.
- **Parser no longer crosses segments.** `Session: [API Error]  Weekly: 16%` read Session as
  16. A segment now ends at its first `%` and is rejected if it holds another label or an error
  token.
- **Tests portable to macOS.** A perl alarm watchdog replaces GNU `timeout`; the two checks
  that were skipped on macOS now run, and every guard-loop invocation is watchdogged so a
  regression fails instead of hanging. New seams `UG_RATE_FILE`, `UG_CCSL_CACHE`,
  `UG_FETCH_CMD` (retry sequences). Suite 19 → 78 checks, 0 skipped; `jq` now required.
- Docs: README had still described the `FAIL_MAX` knob removed in 1.2.0; fixed.

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
