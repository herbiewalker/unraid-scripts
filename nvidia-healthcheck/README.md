<div align="center">

# nvidia-healthcheck

### A one-job watchdog: tell me the moment my Unraid GPU driver stops responding — not when a container silently breaks.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](script.sh)
[![Platform](https://img.shields.io/badge/Unraid-7.2%2B-e8a33d?logo=unraid&logoColor=white)](#install)
[![Notifies](https://img.shields.io/badge/notifies-Unraid%20native-success)](#how-it-works)

Checks that the Nvidia driver is loaded and communicating (`nvidia-smi`), and fires an Unraid notification the instant it isn't.

</div>

## Why it exists

The Nvidia-Driver plugin (ich777) periodically loses its kernel-module binding after an Unraid OS update — the driver has to rebuild against the new kernel, and that rebuild doesn't always happen cleanly. When it fails silently, GPU-dependent Docker containers (in my case, Plex hardware transcoding) fail to start with an opaque error, and it's easy not to notice until something's actively broken.

This catches it the moment it happens, at array start, instead of finding out the hard way.

## How it works

- Runs `nvidia-smi` and checks the exit code — success means the driver is loaded and talking to the GPU.
- On any failure it appends a timestamped line to `/var/log/nvidia-healthcheck.log` **and** raises an Unraid notification (webGUI bell + whatever channels you've configured under **Settings → Notifications** — email, Discord, etc.).
- Distinguishes two failure modes: **`nvidia-smi` not found** (the plugin isn't installed / not on PATH) versus **`nvidia-smi` present but failing** (driver loaded but not responding), so the alert tells you which.
- Wraps the check in a **30-second `timeout`** — a wedged driver can make `nvidia-smi` hang forever, and this check should never hang the array-start job it runs from. A timeout is treated as a failure and alerts like any other.

Self-contained: only `nvidia-smi`, `timeout`, and Unraid's built-in `notify` helper — all present on a stock Unraid box. The script never writes anything except its own log.

## Install

1. Unraid webGUI → **Settings → User Scripts → Add New Script**
2. Name it `nvidia-healthcheck`, paste in [`script.sh`](script.sh)
3. Set schedule to **"At Startup of Array"** — this covers the post-update-reboot case, which is when the binding is most likely to break
4. *(Optional)* also add a periodic cron schedule (e.g. every 6 hours) to catch driver drift outside of reboots

Notifications use Unraid's native system, so no extra configuration is needed beyond whatever channels you already have set under **Settings → Notifications**.

## Optional add-on

The bottom of `script.sh` has a commented-out block that additionally checks a specific container came back up after the driver check passes (e.g. Plex). Uncomment it and set your container name to enable.

## Testing it

You can confirm the notification path works without breaking anything by temporarily pointing the check at a command that will fail — e.g. change `nvidia-smi` to `nvidia-smi-nope` in a copy of the script and run it; you should get the Unraid notification and a `FAILED` line in the log. On a healthy host the real script just logs `OK: driver loaded` and exits 0.

## License

MIT — see [LICENSE](../LICENSE).
