# Changelog — immich-backup

All notable changes to this tool. Format is [Keep a Changelog](https://keepachangelog.com/),
version numbers follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.2.0] — 2026-08-19

### Added
- **Interactive setup TUI** (review-and-confirm screen). Shown on TTY runs of
  `MODE=run`; lists host, dest, sources, include toggles, retention, preflight
  thresholds, and the stop-restart plan; ENTER proceeds, `q`/ESC cancels.
  Skipped on non-TTY runs, `--no-tui`, or `--confirm`.
- **GUI → terminal handoff.** A bare User Scripts click (no TTY + no flags)
  heading for `MODE=run` now prints the "open a terminal and run this" block
  and fires an Unraid notification instead of silently kicking off a real
  backup. Read-only modes (`--list`, `--remind`, `--preflight-only`,
  `--dry-run`, `--verify`) all bypass the handoff. Env-var opt-out:
  `UNRAID_SCRIPTS_NO_HANDOFF=1`.
- **Self-updater.** `--self-update` fetches the latest `script.sh` from GitHub
  raw, `bash -n`-checks it, replaces self, and fires a version-bump
  notification. `--check-update` reports the local/remote version delta.
- **`bootstrap.sh`** you paste into User Scripts once; each run pulls the
  latest script from GitHub (rate-limited to once an hour), syntax-checks,
  caches to flash, execs. Falls back to the cached copy if offline.

### Changed
- `notify_unraid` subject is now `[<host>] <subject>` for fleet clarity.

## [0.1.5] — 2026-08-18

### Added
- `--remind` mode. Fires an Unraid notification with the age of the
  latest backup (looked up from `$DEST_ROOT`) and the command to run
  a new one. Does **no** backup work — safe to schedule at any cadence.
  Icon escalates to `warning` when the last backup is 30+ days old.
  Intended for users who prefer to run backups manually on their own
  schedule but want a monthly nudge.
- README section documents two User Scripts scheduling patterns:
  (A) full daily automated backup, (B) monthly `--remind` nudge only.

## [0.1.4] — 2026-08-18

**First live run on server-b (Unraid 7.3.1).** Ladder rung 5 climbed cleanly.

### Verified live on server-b
- Rung 3 (`--preflight-only`): container discovery matched `immich_server` /
  `immich_machine_learning` / `immich_postgres` / `immich_redis` (grep is
  case-insensitive and matches underscore- and dash-separated names).
- Rung 4 (smallest scope, `--skip-photos`, aggressive retention): 4/4
  containers stopped and restarted cleanly, appdata tarball written
  (~1 GB), compose copied, manifest sha256 verified.
- Rung 5 (full backup): **425 GB rsync of 129,627 photo files in 1h 30m
  at ~80 MB/s.** All phases green; `--verify` and `--list` clean.
- The trap-based stack restart is proven live on this hardware.

### Changed
- README status line no longer carries the "⚠️ never yet run on a live
  target" warning. Ladder verification section describes what has been
  live-tested.
- Quickstart now shows the full-backup one-liner first; the staged climb
  moves to a warning block for new-target installs.

### Fixed
- Cosmetic: `log()`'s `ok`/`warn`/`err` now print `✓`/`!`/`✗` glyphs to
  match `status_line`'s style, instead of the old `OK`/`WARN`/`ERROR`
  word prefixes. Only visual — no behavior change.

## [0.1.3] — 2026-08-18

### Fixed
- **Preflight was O(files)** — `check_free_space` ran `du -sxk` on the
  photo library (432 GB, ~500k files on server-b), stalling preflight for
  several minutes and looking hung. Preflight is now `df`-based
  (constant-time): it reports free space on the dest and aborts if it
  falls below the guardrail, but does not measure the sources.

### Added
- `--min-free-gb N` — abort preflight if dest has less than N GB free
  (default: 50).
- `--strict-space` — opt-in flag that runs the old slow `du -sx`
  measurement against the sources. Prints a warning that it may take
  several minutes.

## [0.1.2] — 2026-08-18

### Changed
- Default `--dest` is now `/mnt/user/data/backup_immich` (previously
  `/mnt/user/backup/immich`). The server-b diag confirms the `data` share
  already exists on disk1 with `cache_downloads` pool, so the tool's
  default now lands on a real share out of the box instead of asking
  the user to create a new one.

## [0.1.1] — 2026-08-18

First server-b preflight round found two bugs; fixed both. Still **never yet run**
past `--dry-run` on a live target.

### Fixed
- `--dry-run` (and the run-mode preflight) crashed with
  `No such file or directory` on the log file because `LOG_FILE` pointed inside
  `$DEST_ROOT` before that directory existed. `LOG_FILE` now starts in `/tmp`
  and is promoted into `$DEST_ROOT` after preflight passes (real runs only).
- `check_dest` returned `✓ dest writable` as a false positive when
  `$DEST_ROOT` didn't exist yet (in `--preflight-only` and `--dry-run`).
  It now probes the parent share for writability and reports the parent it
  verified, so the ✓ is meaningful.

### Verified on server-b (rung 3)
- Container discovery: `immich_server`, `immich_machine_learning`,
  `immich_postgres`, `immich_redis` — grep matches underscores as well as
  dashes.
- Server-identity block populates correctly on real Unraid 7.3.1.

## [0.1.0] — 2026-08-18

Initial scaffold. **Never yet run on a live target.** First live command must be
`--preflight-only` on server-b. Full climb of the validation ladder is required before
this line is removed.

### Added
- Single-file `script.sh` bash tool with modes: `--run` (default), `--preflight-only`,
  `--dry-run`, `--verify`, `--restore` (stubbed), `--list`, `--help`.
- Stop-stack → snapshot → restart-stack flow, with an EXIT/INT/TERM trap that guarantees
  the Immich stack is restarted even on Ctrl-C or a mid-run failure. Exit code `3`
  reserved for the failure of that restart.
- Three toggleable components: `--skip-photos`, `--skip-appdata`, `--skip-compose`.
- GFS retention: `--keep-daily N`, `--keep-weekly N`, `--keep-monthly N`
  (defaults 7 / 4 / 6).
- Fresh-look ANSI TUI (box-drawn banner, phase blocks with colored PASS/WARN/FAIL);
  `--quiet` mode for cron / User Scripts.
- Server-identity block + `manifest.json` (versions, sizes, sha256s, host, machine-id,
  Unraid version, kernel, CPU, RAM, board, uptime). Safe set only — no serials, MAC,
  or flash GUID. Matches DeepScan / hardware-stress-test conventions.
- Preflight checks: root, deps, source paths, dest writable, free-space margin,
  no other backup running (lockfile at `/var/lock/immich-backup.lock`), Immich
  containers discoverable.
- Ladder plumbing: `--preflight-only` (rung 3) and `--dry-run` (rung 2) both
  wired end-to-end. Live-scope rungs 4 and 5 are the same code path guarded by
  the same trap.
- `--verify PATH`: reads `manifest.json`, checks `appdata.tar.gz` sha256 and
  tarball readability, counts photos files.
- README with staged first-run block, phase table, exit-code table, GFS retention
  rules, TUI mockup, User Scripts cron snippet, and the "never yet verified until
  first live run" list.
- Unraid notifications on the three moments that matter: clean finish
  (with dated stamp + total size), non-clean rc (backup failed but stack
  restarted), and the reserved-code-3 case (stack restart itself failed —
  fired as `alert`). No-ops on non-Unraid hosts.

### Deferred (known, listed on purpose)
- `--restore` refuses to run in v0.1. Full restore path lands in v0.2 once
  `--run` has one green live-target run and the failure modes are understood.
- No offsite mirror (out of scope — pair with rclone against `--dest`).
- No encryption at rest (belongs to the destination layer, not this tool).

[Unreleased]: #
[0.1.0]: #
