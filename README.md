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

## Scripts

### [`DeepScanScriptClaude/`](DeepScanScriptClaude) — read-only fleet storage-scan

Deep-scans `/mnt/user` — top dirs and files, age histogram, duplicate finder, BTRFS/ZFS pool stats, Docker/VM disk usage, trash locations, oversized logs — and packages everything into one tarball for file-level "where is my space going" analysis. 16 phases, `--quick` mode, JSON summary. See [DeepScanScriptClaude/README.md](DeepScanScriptClaude/README.md) for the full phase table and [README-install.md](DeepScanScriptClaude/README-install.md) to install.

### [`nvidia-healthcheck/`](nvidia-healthcheck) — GPU driver watchdog

Checks whether the Nvidia GPU driver is loaded and communicating (`nvidia-smi`) and fires an Unraid notification if it isn't — catching the case where the Nvidia-Driver plugin (ich777) silently fails to rebind its kernel module after an Unraid OS update, which otherwise shows up as GPU-dependent containers (e.g. Plex hardware transcoding) failing with an opaque error. Runs at array start; see [nvidia-healthcheck/README.md](nvidia-healthcheck/README.md) for how it works and install steps.

### [`hardware-stress-test/`](hardware-stress-test) — CPU + RAM stress test with crash forensics

Stress-tests CPU and RAM using **only what ships with Unraid** — no Nerd Tools (deprecated), no package installs, no Docker. Three phases: CPU (AES-NI + SHA-512), RAM write/verify (a checksum mismatch means a bit flipped — a hardware fault), then both together.

The point isn't the pass/fail. Unraid's syslog lives in tmpfs, so a hard lockup destroys its own evidence. This script writes a **heartbeat every 15s to the flash drive** (`sync`'d immediately) and to syslog — so if the box freezes solid, you reboot and the last line tells you the phase, the elapsed time, and the temperature at death. Runs natively rather than in a container, deliberately, so that a crash doesn't leave you unable to tell the CPU from the container runtime. **Stop the array before running** — the test doesn't need it, and an unclean shutdown with the array stopped is harmless. See [hardware-stress-test/README.md](hardware-stress-test/README.md).

## License

MIT — see [LICENSE](LICENSE).
