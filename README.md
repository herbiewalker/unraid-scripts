<div align="center">

# unraid-scripts

### Read-only, self-contained Unraid User Scripts — no installs, no writes outside their own working directory.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](#scripts)
[![Platform](https://img.shields.io/badge/Unraid-7.2%2B-e8a33d?logo=unraid&logoColor=white)](#scripts)
[![Scripts](https://img.shields.io/badge/scripts-read--only-success)](#scripts)

Personal collection of [User Scripts plugin](https://forums.unraid.net/topic/47536-plugin-ca-user-scripts/) scripts, built and run across a fleet of three Unraid servers — server-a, server-b, and server-c.

</div>

## Why these exist

- 🔍 **Built for a real fleet, not a demo.** Every script here runs on three actual servers spanning a 3.7 TB array to a 97 TB array — the runtime estimates and edge cases in each script's docs come from that spread, not guesswork.
- 🔒 **Read-only by construction.** Any script that touches disk enforces (via a grep-checkable invariant, documented in its own README) that it never `mv`s or `dd`s, and touches `rm` only inside its own intermediate working files — never your shares.
- 📦 **Self-contained.** No `jq`, no package installs, no dependencies beyond what ships with Unraid base + the User Scripts plugin.
- 🖥️ **Runs from the webGUI.** Every script here is a single file that drops straight into **Settings → User Scripts** — no SSH required to use one, just to install it.
- 🏷️ **Fleet-attributable output.** Each script stamps its logs (and, where relevant, its JSON summary and a `00-server.txt`) with a server-identity block — hostname, machine-id, Unraid version, kernel, CPU, RAM, board, uptime — so when you run them across several boxes you always know which one a result came from. Safe set only: no hardware serials, MAC, or flash GUID.

## Install — the auto-update bootstrap (paste once, stay fresh)

Every tool in this repo now ships with a small `bootstrap.sh` next to its `script[.sh]`. Paste the bootstrap into **Settings → User Scripts → Add New Script → Edit** *once* and the User Scripts run will:

1. Fetch the latest `script[.sh]` from GitHub raw (`main` branch),
2. `bash -n`-check it before touching disk,
3. Cache it to flash at `/boot/config/plugins/user.scripts/scripts/<tool>/`,
4. Fire an Unraid notification whenever a new version replaces the cached one,
5. Fall back to the cached copy if the fetch or syntax check fails (safe when the LAN is down),
6. Rate-limit the fetch to once an hour so quick re-runs don't hit GitHub every time.

**No more SSH-and-copy on every update** — merge a new version to `main` and the next User Scripts run pulls it. Opt-out env vars:

- `UNRAID_SCRIPTS_NO_UPDATE=1` — skip the fetch, always run the cached copy
- `UNRAID_SCRIPTS_NO_HANDOFF=1` — silence the "open a terminal" nudge on bare GUI clicks
- `UNRAID_SCRIPTS_ASCII=1` — fall back to ASCII glyphs (`v x ! > o ->`) on limited terminals
- `NO_COLOR=1` — disable ANSI colors

Each real script also has manual controls: `--check-update` (report version delta) and `--self-update` (fetch + install now).

Bootstrap files:
- [`DeepScanScriptClaude/bootstrap.sh`](DeepScanScriptClaude/bootstrap.sh)
- [`hardware-stress-test/bootstrap.sh`](hardware-stress-test/bootstrap.sh)
- [`immich-backup/bootstrap.sh`](immich-backup/bootstrap.sh)
- [`nvidia-healthcheck/bootstrap.sh`](nvidia-healthcheck/bootstrap.sh)

## Scripts

### [`DeepScanScriptClaude/`](DeepScanScriptClaude) v0.4.0 — read-only fleet storage-scan

Deep-scans `/mnt/user` — top dirs and files, age histogram, duplicate finder, BTRFS/ZFS pool stats, Docker/VM disk usage, trash locations, oversized logs — and packages everything into one tarball for file-level "where is my space going" analysis. 16 phases, `--quick` mode, JSON summary. Run it from a terminal for an **interactive setup screen** (Quick/Full, all-extensions toggle); a bare click in the User Scripts GUI **hands off to a terminal** (fires a notification with the exact command to run) instead of silently running defaults. Passing any flag bypasses the handoff, and the completed scan fires an Unraid notification with the tarball location. Ships `--self-update` / `--check-update` and a [bootstrap.sh](DeepScanScriptClaude/bootstrap.sh) that keeps User Scripts fresh from GitHub automatically. See [DeepScanScriptClaude/README.md](DeepScanScriptClaude/README.md) for the full phase table and [README-install.md](DeepScanScriptClaude/README-install.md) to install.

### [`nvidia-healthcheck/`](nvidia-healthcheck) v0.2.0 — GPU driver watchdog

Checks whether the Nvidia GPU driver is loaded and communicating (`nvidia-smi`) and fires an Unraid notification if it isn't — catching the case where the Nvidia-Driver plugin (ich777) silently fails to rebind its kernel module after an Unraid OS update, which otherwise shows up as GPU-dependent containers (e.g. Plex hardware transcoding) failing with an opaque error. Runs at array start; deliberately lean, no TUI. Ships `--self-update` / `--check-update` and a [bootstrap.sh](nvidia-healthcheck/bootstrap.sh) for auto-fresh User Scripts installs. See [nvidia-healthcheck/README.md](nvidia-healthcheck/README.md) for how it works and install steps.

### [`immich-backup/`](immich-backup) v0.2.0 — stop-the-stack Immich backup for Unraid

Backs up an Immich stack the safe way: **stop the containers → snapshot the photos share + the appdata tree + the compose file → restart the stack → rotate**. Because the containers are stopped during the copy, the Postgres data files are quiescent and the archive is a consistent restore-point without a live `pg_dump`. Grandfather–Father–Son retention (default 7 daily / 4 weekly / 6 monthly) keeps [`DeepScanScriptClaude`](DeepScanScriptClaude)'s stale-backup warning quiet without unbounded disk use.

v0.2.0 adds an **interactive review-and-confirm setup TUI** for real backup runs on a terminal, and a **scoped GUI → terminal handoff** — a bare User Scripts click heading for a live backup fires the "open a terminal and run this" nudge instead of touching disk, while `--list` / `--remind` / `--preflight-only` / `--dry-run` / `--verify` all bypass so scheduled cron and read-only ops keep working non-interactively.

The **one line of code that matters** is the EXIT/INT/TERM trap that guarantees the stack restarts — Ctrl-C, crash, docker error, anything. Exit code `3` is reserved for the case where that restart itself fails so the notification is unambiguous. First live run on 2026-08-18: 425 GB rsync of 129,627 photo files in 1h 30m, stack stopped and restarted 4/4 cleanly, manifest sha256 verified — the trap-based restart is proven on real hardware. `--restore` remains deliberately stubbed until we've depended on the backup for a real recovery. Ships `--self-update` / `--check-update` and a [bootstrap.sh](immich-backup/bootstrap.sh). See [immich-backup/README.md](immich-backup/README.md).

### [`hardware-stress-test/`](hardware-stress-test) v0.3.0 — CPU + RAM stress test with crash forensics

Stress-tests CPU and RAM using **only what ships with Unraid** — no Nerd Tools (deprecated), no package installs, no Docker (it uses `stress-ng` only if you already have it). Three phases: CPU, RAM write/verify, then both together, in Quick / Standard / Burn-in profiles.

The point isn't the pass/fail — the load only provokes a fault. The evidence comes from the hardware's own counters: **live ECC/EDAC error counts** (an uncorrectable error aborts on the spot), machine-check exceptions, and thermal-throttle events, with a tmpfs checksum loop as the non-ECC fallback. Because Unraid's syslog lives in tmpfs, a hard lockup destroys its own evidence, so the script writes a **heartbeat to the flash drive** (`sync`'d immediately) and to syslog — reboot after a freeze and the last line gives you the phase, elapsed time, temperature, and ECC state at death. Run it from a terminal for an **interactive setup screen** (profiles, live preflight, runtime estimate); click Run in the User Scripts GUI and it **hands you off to a terminal** (a one-way log pane can't host the screen) or takes flags for an unattended run. A real thermal abort, a preflight that **refuses to start with the array running**, and cleanup on every exit path. Ships `--self-update` / `--check-update` and a [bootstrap.sh](hardware-stress-test/bootstrap.sh). See [hardware-stress-test/README.md](hardware-stress-test/README.md).

## License

MIT — see [LICENSE](LICENSE).
