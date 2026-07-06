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

SMI_OUTPUT=$(nvidia-smi 2>&1)
SMI_EXIT=$?

if [ $SMI_EXIT -ne 0 ]; then
  echo "$TIMESTAMP - FAILED: $SMI_OUTPUT" >> "$LOGFILE"

  /usr/local/emhttp/webGui/scripts/notify \
    -e "Nvidia Driver Check" \
    -s "GPU driver not loaded" \
    -d "nvidia-smi failed — GPU-dependent containers (e.g. Plex hardware transcoding) won't work until this is fixed. Error: ${SMI_OUTPUT}" \
    -i "alert"

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
