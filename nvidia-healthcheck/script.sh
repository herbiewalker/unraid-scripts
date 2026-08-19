#!/bin/bash
#
# Nvidia GPU Health Check v0.2.0 — notifies via Unraid's built-in system
# if the Nvidia driver isn't loaded/communicating (common right
# after an Unraid OS update, before you notice a GPU-dependent
# container is broken).
#
# Install via the User Scripts plugin. Recommended schedule:
# "At Startup of Array". See ../README.md for details.
#
# Flags:
#   --self-update    Fetch the latest script.sh from GitHub, replace self, exit
#   --check-update   Compare local vs. remote version, exit
#   --version        Print version and exit
#
# Env vars:
#   UNRAID_SCRIPTS_NO_UPDATE=1   (respected by bootstrap.sh, not this script)

set -u

VERSION="0.2.0"
TOOL="nvidia-healthcheck"

UPDATE_REPO="herbiewalker/unraid-scripts"
UPDATE_BRANCH="main"
UPDATE_URL="https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}/${TOOL}/script.sh"

LOGFILE="/var/log/nvidia-healthcheck.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOST=$(hostname 2>/dev/null || echo unknown)

alert() {
  /usr/local/emhttp/webGui/scripts/notify \
    -e "$TOOL" -s "[$HOST] $1" -d "$2" -i "alert"
}

self_path() { local p="${BASH_SOURCE[0]:-$0}"; readlink -f "$p" 2>/dev/null || printf '%s' "$p"; }

_script_version_of() {
  grep -oE '^(SCRIPT_VERSION|VERSION)="[0-9]+\.[0-9]+\.[0-9]+"' "$1" 2>/dev/null \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

check_update() {
  local tmp; tmp=$(mktemp 2>/dev/null) || tmp="/tmp/${TOOL}.check.$$"
  if ! curl -fsSL --max-time 15 "$UPDATE_URL" -o "$tmp" 2>/dev/null; then
    echo "could not reach $UPDATE_URL"; rm -f "$tmp"; return 1
  fi
  local remote; remote=$(_script_version_of "$tmp"); rm -f "$tmp"
  [ -z "$remote" ] && { echo "remote fetched but version not parseable"; return 1; }
  echo "local:  $VERSION"
  echo "remote: $remote"
  if [ "$VERSION" = "$remote" ]; then echo "up to date"
  else echo "new version available — run: $(self_path) --self-update"
  fi
}

self_update() {
  local target; target=$(self_path)
  local tmp; tmp=$(mktemp 2>/dev/null) || tmp="/tmp/${TOOL}.upd.$$"
  echo "fetching $UPDATE_URL ..."
  curl -fsSL --max-time 30 "$UPDATE_URL" -o "$tmp" || { echo "fetch failed" >&2; rm -f "$tmp"; return 1; }
  bash -n "$tmp" 2>/dev/null || { echo "downloaded file failed bash -n; keeping current copy" >&2; rm -f "$tmp"; return 1; }
  local new_ver; new_ver=$(_script_version_of "$tmp")
  [ -n "$new_ver" ] || { echo "downloaded file has no parseable VERSION; refusing" >&2; rm -f "$tmp"; return 1; }
  install -m 0755 "$tmp" "$target"
  rm -f "$tmp"
  echo "updated: $VERSION → $new_ver  ($target)"
  [ -x /usr/local/emhttp/webGui/scripts/notify ] && \
    /usr/local/emhttp/webGui/scripts/notify \
      -e "$TOOL" -s "[$HOST] Updated to v$new_ver" \
      -d "$TOOL updated from v$VERSION to v$new_ver via --self-update." -i "normal"
  return 0
}

case "${1:-}" in
  --self-update)  self_update;  exit $? ;;
  --check-update) check_update; exit $? ;;
  --version)      echo "$TOOL $VERSION"; exit 0 ;;
  --help|-h)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

# nvidia-smi missing entirely means the Nvidia-Driver plugin isn't
# installed (or isn't on PATH) — a different problem than a driver that
# is present but not responding, so give it its own message.
if ! command -v nvidia-smi &>/dev/null; then
  echo "$TIMESTAMP [$HOST] - FAILED: nvidia-smi not found" >> "$LOGFILE"
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
  echo "$TIMESTAMP [$HOST] - FAILED (exit $SMI_EXIT): $SMI_OUTPUT" >> "$LOGFILE"
  alert "GPU driver not loaded" \
    "nvidia-smi failed (exit $SMI_EXIT) — GPU-dependent containers (e.g. Plex hardware transcoding) won't work until this is fixed. Error: ${SMI_OUTPUT}"
  exit 1
else
  echo "$TIMESTAMP [$HOST] - OK: driver loaded" >> "$LOGFILE"
  exit 0
fi

# --- Optional add-on ---
# Uncomment to also confirm a specific container came back up after
# the driver check passes (e.g. Plex). Edit the container name below.
#
# if ! docker ps --format '{{.Names}}' | grep -q '^binhex-plexpass$'; then
#   /usr/local/emhttp/webGui/scripts/notify \
#     -e "Plex Container Check" \
#     -s "[$HOST] binhex-plexpass not running" \
#     -d "Nvidia driver is fine, but the Plex container isn't up. Check manually." \
#     -i "warning"
# fi
