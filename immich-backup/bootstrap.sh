#!/bin/bash
# immich-backup bootstrap — paste into Unraid User Scripts once.
#
# On each User Scripts run this fetches the latest script from GitHub, syntax-
# checks it, caches to flash, and execs it. Falls back to the cached local copy
# if the fetch or syntax check fails. Fires an Unraid notification when a new
# version is installed.
#
# Env vars:
#   UNRAID_SCRIPTS_NO_UPDATE=1     skip the fetch, always run the cached copy
#   UNRAID_SCRIPTS_NO_HANDOFF=1    passed through — silences the terminal handoff
#
# See: https://github.com/herbiewalker/unraid-scripts

set -u

TOOL="immich-backup"
SCRIPT_NAME="script.sh"
REPO="herbiewalker/unraid-scripts"
BRANCH="main"

LOCAL_DIR="/boot/config/plugins/user.scripts/scripts/${TOOL}"
LOCAL="${LOCAL_DIR}/${SCRIPT_NAME}"
URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${TOOL}/${SCRIPT_NAME}"
CACHE_MAX_AGE_SEC=3600

notify() {
    [ -x /usr/local/emhttp/webGui/scripts/notify ] || return 0
    local host; host=$(hostname 2>/dev/null || echo unknown)
    /usr/local/emhttp/webGui/scripts/notify \
        -e "${TOOL} bootstrap" -s "[$host] $1" -d "$2" -i "${3:-normal}" 2>/dev/null
}

version_of() {
    grep -oE '^(SCRIPT_VERSION|VERSION)="[0-9]+\.[0-9]+\.[0-9]+"' "$1" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

mkdir -p "$LOCAL_DIR"

should_fetch=1
if [ "${UNRAID_SCRIPTS_NO_UPDATE:-0}" = "1" ]; then
    should_fetch=0
elif [ -f "$LOCAL" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$LOCAL" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$CACHE_MAX_AGE_SEC" ] && should_fetch=0
fi

if [ "$should_fetch" = 1 ]; then
    tmp=$(mktemp 2>/dev/null || echo "/tmp/${TOOL}.bootstrap.$$")
    if curl -fsSL --max-time 20 "$URL" -o "$tmp" 2>/dev/null; then
        if bash -n "$tmp" 2>/dev/null; then
            old_ver=$(version_of "$LOCAL")
            new_ver=$(version_of "$tmp")
            if [ -n "$new_ver" ]; then
                install -m 0755 "$tmp" "$LOCAL"
                if [ -n "$old_ver" ] && [ "$old_ver" != "$new_ver" ]; then
                    notify "Updated to v${new_ver}" \
                        "${TOOL} auto-updated from v${old_ver} to v${new_ver} (source: ${REPO}@${BRANCH})." \
                        "normal"
                fi
            fi
        else
            notify "Update skipped — syntax error" \
                "Downloaded ${TOOL} from ${URL} failed bash -n. Keeping local copy." "warning"
        fi
    fi
    rm -f "$tmp"
fi

if [ ! -f "$LOCAL" ]; then
    echo "${TOOL} bootstrap: local script missing and fetch failed" >&2
    notify "Bootstrap failed" \
        "Could not fetch ${URL} and no cached copy at ${LOCAL}." "alert"
    exit 1
fi

chmod +x "$LOCAL" 2>/dev/null
exec bash "$LOCAL" "$@"
