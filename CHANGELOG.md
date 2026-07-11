# Changelog

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
