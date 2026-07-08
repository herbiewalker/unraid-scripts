#!/bin/bash
#
# Nvidia GPU Health Check — notifies via Unraid's built-in system
# if the Nvidia driver isn't loaded/communicating (common right
# after an Unraid OS update, before you notice a GPU-dependent
# container is broken).
#
# Install via the User Scripts plugin. Recommended schedule:
# "At Startup of Array". See ../README.md for details.

LOGFILE="/var/log/nvidia-healthcheck.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Wrap Unraid's notify helper so both failure paths stay one line each.
alert() {
  /usr/local/emhttp/webGui/scripts/notify \
    -e "Nvidia Driver Check" -s "$1" -d "$2" -i "alert"
}

# nvidia-smi missing entirely means the Nvidia-Driver plugin isn't
# installed (or isn't on PATH) — a different problem than a driver that
# is present but not responding, so give it its own message.
if ! command -v nvidia-smi &>/dev/null; then
  echo "$TIMESTAMP - FAILED: nvidia-smi not found" >> "$LOGFILE"
  alert "nvidia-smi not found" \
    "nvidia-smi is not on PATH — is the Nvidia-Driver plugin installed? GPU-dependent containers (e.g. Plex hardware transcoding) won't work."
  exit 1
fi

# A wedged driver can make nvidia-smi hang indefinitely — exactly the
# state this check exists to catch. Cap it with timeout (ships with
# Unraid's coreutils) so the check can never hang the User Scripts job.
# A timeout exits 124, which is non-zero, so it still fires the alert.
SMI_OUTPUT=$(timeout 30 nvidia-smi 2>&1)
SMI_EXIT=$?

if [ "$SMI_EXIT" -ne 0 ]; then
  echo "$TIMESTAMP - FAILED (exit $SMI_EXIT): $SMI_OUTPUT" >> "$LOGFILE"
  alert "GPU driver not loaded" \
    "nvidia-smi failed (exit $SMI_EXIT) — GPU-dependent containers (e.g. Plex hardware transcoding) won't work until this is fixed. Error: ${SMI_OUTPUT}"
  exit 1
else
  echo "$TIMESTAMP - OK: driver loaded" >> "$LOGFILE"
  exit 0
fi

# --- Optional add-on ---
# Uncomment to also confirm a specific container came back up after
# the driver check passes (e.g. Plex). Edit the container name below.
#
# if ! docker ps --format '{{.Names}}' | grep -q '^binhex-plexpass$'; then
#   /usr/local/emhttp/webGui/scripts/notify \
#     -e "Plex Container Check" \
#     -s "binhex-plexpass not running" \
#     -d "Nvidia driver is fine, but the Plex container isn't up. Check manually." \
#     -i "warning"
# fi
