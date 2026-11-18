#!/bin/bash
# ╭──────────────────────────────────────────────────────────────────╮
# │  ┌●───●───●───●───●───●───●───●───●───●───●───●───●───●───●───┐  │
# │  │                                                            │  │
# │  ●   ██╗  ██╗    ██╗    ██╗                                   ●  │
# │  │   ██║  ██║    ██║    ██║           herbiewalker            │  │
# │  │   ███████║    ██║ █╗ ██║──●──●──●──┐                       │  │
# │  │   ██╔══██║    ██║███╗██║           │                       │  │
# │  ●   ██║  ██║    ╚███╔███╔╝           ●───⏣  code · tools     ●  │
# │  │   ╚═╝  ╚═╝     ╚══╝╚══╝                    homelab         │  │
# │  │                                                            │  │
# │  └●───●───●───●───●───●───●───●───●───●───●───●───●───●───●───┘  │
# ╰──────────────────────────────────────────────────────────────────╯
# media-lockdown v0.1.0
#
# Finds things that should never be in a media library — executables,
# scripts, installers, setuid files, and EXE/ELF/scripts renamed to .mkv —
# in the folders YOU pick, then (optionally) defuses them. Built for the
# Plex/Jellyfin + *arr setup: it never changes write permission, ownership,
# or folder modes, never touches files newer than --min-age, and never
# deletes anything, so upgrades/replacements (1080p -> 4K) and library
# scans keep working untouched.
#
#   scan  (default)  report only — changes nothing
#   fix              quarantine HIGH findings (moved, never deleted) and
#                    strip exec/setuid bits (chmod a-x,u-s,g-s) from MED ones
#
# Usage: script.sh                       interactive TUI (pick folders, review, run)
#        script.sh --scan  [--path P]... non-interactive, uses saved folders
#        script.sh --fix --apply [...]   non-interactive fix
#        script.sh --discover | --docker-audit | --list | --restore MANIFEST
# See:   README.md, or `script.sh --help`
#
# Exit: 0 clean · 1 usage/config error · 2 HIGH findings present (scan)
#       3 fix finished with errors · 130 interrupted

set -uo pipefail
# set -e intentionally OFF: one unreadable file must not abort the whole pass.

VERSION="0.1.0"
TOOL="media-lockdown"

# ---- self-update source (see --self-update / --check-update) --------------
UPDATE_REPO="herbiewalker/unraid-scripts"
UPDATE_BRANCH="main"
UPDATE_URL="https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}/${TOOL}/script.sh"

# --- locations --------------------------------------------------------------
CONF_DIR="${ML_CONF_DIR:-/boot/config/plugins/${TOOL}}"
CONF_FILE="${CONF_DIR}/${TOOL}.conf"
WORK_DIR="/mnt/user/appdata/${TOOL}"          # logs/ + quarantine/ live here

# --- tunables (saved/loaded via the config file; flags override) ------------
PATHS=()                  # folders to check (the "lockdown" set)
EXCLUDES=()               # sub-paths relative to each PATH to skip
MIN_AGE=60                # minutes; newer files are never flagged or touched
DEEP=0                    # read first bytes of media files (disguised EXE/ELF/script)
STRICT=0                  # fix also quarantines unknown extensions
ALLOW_EXTRA=()            # extra extensions treated as OK
MEDIA_CONTAINERS='plex|jellyfin|emby|sonarr|radarr|lidarr|readarr|bazarr|whisparr'
OTHER_CONTAINERS='sabnzbd|nzbget|qbit|deluge|transmission|prowlarr|jackett'

ALLOW_EXT=(mkv mp4 m4v avi mov wmv flv webm ts m2ts mts mpg mpeg vob divx ogv 3gp
           mp3 flac m4a m4b aac ogg opus wav wma ape alac aiff
           srt ass ssa sub idx vtt sup smi lrc
           jpg jpeg png webp gif bmp tbn
           nfo xml cue m3u m3u8 epub mobi azw3 pdf cbz cbr)
BENIGN_NAMES=(.DS_Store Thumbs.db desktop.ini .plexmatch .ignore .nomedia)
DANGEROUS_EXT=(exe com scr bat cmd msi msp dll lnk pif ps1 psm1 vbs vbe js jse wsf wsh
               hta cpl reg jar apk app dmg pkg deb rpm appimage run bin sh bash zsh ksh
               csh py pl rb php phtml cgi so ko)
ARCHIVE_EXT=(rar zip 7z tar gz tgz bz2 xz zst par2 sfv)

# --- flags ------------------------------------------------------------------
MODE="run"                # run | scan | fix | discover | docker | list | restore | help | version | selfupdate | checkupdate
APPLY=0; DETAIL=0; NOTIFY=0; NO_TUI=0; QUIET=0; SAVE=0
CLI_PATHS=()
RESTORE_FILE=""

# --- ANSI / glyphs ----------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
    C_RED=$'\e[31m';  C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
    C_BLU=$'\e[34m';  C_CYN=$'\e[36m'; C_MAG=$'\e[35m'; C_INV=$'\e[7m'
else
    C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""
    C_BLU=""; C_CYN=""; C_MAG=""; C_INV=""
fi
if [ "${UNRAID_SCRIPTS_ASCII:-0}" = "1" ]; then
    G_OK="v"; G_BAD="x"; G_WARN="!"; G_INFO=">"; G_DOT="o"; G_ARROW="->"; G_STAR="*"
else
    G_OK="✓"; G_BAD="✗"; G_WARN="⚠"; G_INFO="▶"; G_DOT="●"; G_ARROW="→"; G_STAR="★"
fi

# --- state ------------------------------------------------------------------
declare -A SEV WHY ROOT_OF DET
LOG_FILE=""
HIGH_COUNT=0; MED_COUNT=0; LOW_COUNT=0
DEMO_HOST=""; DEMO_MID=""; DEMO_UNRAID=""; DEMO_KERNEL=""
DEMO_CPU=""; DEMO_RAM=""; DEMO_BOARD=""; DEMO_UPTIME=""
BOX_W=76

# =========================================================================
# LOGGING
# =========================================================================
log() {
    local msg="$*"
    if [ -n "$LOG_FILE" ]; then
        printf '%s %s\n' "$(date '+%F %T')" "$(printf '%s' "$msg" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g')" >>"$LOG_FILE" 2>/dev/null
    fi
    [ "$QUIET" = "1" ] || printf '%s\n' "$msg"
}
say()  { [ "$QUIET" = "1" ] || printf '%s\n' "$*"; }
ok()   { log "  ${C_GRN}${G_OK}${C_RESET} $*"; }
warn() { log "  ${C_YEL}${G_WARN}${C_RESET} $*"; }
err()  { QUIET_SAVE=$QUIET; QUIET=1; log "  ${C_RED}${G_BAD}${C_RESET} $*"; QUIET=$QUIET_SAVE; printf '  %s%s%s %s\n' "$C_RED" "$G_BAD" "$C_RESET" "$*" >&2; }
QUIET_SAVE=0
die()  { err "$*"; exit 1; }

notify_unraid() {
    local subj="$1" desc="$2" icon="${3:-normal}"
    [ -x /usr/local/emhttp/webGui/scripts/notify ] || return 0
    local h; h=$(hostname 2>/dev/null || echo unknown)
    /usr/local/emhttp/webGui/scripts/notify \
        -e "${TOOL}" -s "${BRAND_SIGIL} [$h] $subj" -d "$desc" -i "$icon" 2>/dev/null
    return 0
}

# =========================================================================
# SELF-UPDATE
# =========================================================================
self_path() { local p="${BASH_SOURCE[0]:-$0}"; readlink -f "$p" 2>/dev/null || printf '%s' "$p"; }

_script_version_of() {
    grep -oE '^(SCRIPT_VERSION|VERSION)="[0-9]+\.[0-9]+\.[0-9]+"' "$1" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

check_update() {
    local tmp; tmp=$(mktemp 2>/dev/null) || tmp="/tmp/${TOOL}.check.$$"
    if ! curl -fsSL --max-time 15 "$UPDATE_URL" -o "$tmp" 2>/dev/null; then
        printf '  %s%s%s could not reach %s\n' "$C_YEL" "$G_BAD" "$C_RESET" "$UPDATE_URL"
        rm -f "$tmp"; return 1
    fi
    local remote; remote=$(_script_version_of "$tmp"); rm -f "$tmp"
    if [ -z "$remote" ]; then
        printf '  %s%s%s remote fetched but version not parseable\n' "$C_YEL" "$G_WARN" "$C_RESET"
        return 1
    fi
    printf '  local:  %s\n  remote: %s\n' "$VERSION" "$remote"
    if [ "$VERSION" = "$remote" ]; then
        printf '  %s%s%s up to date\n' "$C_GRN" "$G_OK" "$C_RESET"
    else
        printf '  %s%s%s new version available — run: %s --self-update\n' \
            "$C_YEL" "$G_INFO" "$C_RESET" "$(self_path)"
    fi
    return 0
}

self_update() {
    local target; target=$(self_path)
    if [ ! -w "$target" ] && [ ! -w "$(dirname "$target")" ]; then
        printf '  %s%s%s cannot write %s — need root\n' "$C_RED" "$G_BAD" "$C_RESET" "$target" >&2
        return 1
    fi
    local tmp; tmp=$(mktemp 2>/dev/null) || tmp="/tmp/${TOOL}.upd.$$"
    printf '  fetching %s ...\n' "$UPDATE_URL"
    if ! curl -fsSL --max-time 30 "$UPDATE_URL" -o "$tmp"; then
        printf '  %s%s%s fetch failed\n' "$C_RED" "$G_BAD" "$C_RESET" >&2; rm -f "$tmp"; return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        printf '  %s%s%s downloaded file failed bash -n; keeping current copy\n' "$C_RED" "$G_BAD" "$C_RESET" >&2
        rm -f "$tmp"; return 1
    fi
    local new_ver; new_ver=$(_script_version_of "$tmp")
    if [ -z "$new_ver" ]; then
        printf '  %s%s%s downloaded file has no parseable VERSION; refusing\n' "$C_RED" "$G_BAD" "$C_RESET" >&2
        rm -f "$tmp"; return 1
    fi
    install -m 0755 "$tmp" "$target"; rm -f "$tmp"
    printf '  %s%s%s updated: %s %s %s  (%s)\n' "$C_GRN" "$G_OK" "$C_RESET" "$VERSION" "$G_ARROW" "$new_ver" "$target"
    notify_unraid "Updated to v$new_ver" \
        "$TOOL updated from v$VERSION to v$new_ver via --self-update (source: $UPDATE_REPO@$UPDATE_BRANCH)." "normal"
    return 0
}

# =========================================================================
# DEMOGRAPHICS (safe set — matches the other herbiewalker tools)
# =========================================================================
demo_collect() {
    DEMO_HOST="$(hostname 2>/dev/null || echo unknown)"
    DEMO_MID="$(cat /etc/machine-id 2>/dev/null || echo unknown)"
    if [ -r /etc/unraid-version ]; then
        DEMO_UNRAID="$(. /etc/unraid-version 2>/dev/null; echo "${version:-unknown}")"
    else
        DEMO_UNRAID="not-unraid"
    fi
    DEMO_KERNEL="$(uname -r 2>/dev/null || echo unknown)"
    DEMO_CPU="$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//')"
    [ -z "$DEMO_CPU" ] && DEMO_CPU="unknown"
    local ram_kb; ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$ram_kb" ]; then DEMO_RAM="$(( ram_kb / 1024 / 1024 )) GB"; else DEMO_RAM="unknown"; fi
    DEMO_BOARD="$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)"
    DEMO_UPTIME="$(awk '{printf "%.1f days\n", $1/86400}' /proc/uptime 2>/dev/null || echo unknown)"
}

demo_report() {
    [ "$QUIET" = "1" ] && return
    say ""
    say "${C_DIM}  host       ${C_RESET}$DEMO_HOST"
    say "${C_DIM}  unraid     ${C_RESET}$DEMO_UNRAID  (kernel $DEMO_KERNEL)"
    say "${C_DIM}  cpu / ram  ${C_RESET}$DEMO_CPU  ·  $DEMO_RAM"
    say "${C_DIM}  board      ${C_RESET}$DEMO_BOARD"
    say "${C_DIM}  uptime     ${C_RESET}$DEMO_UPTIME"
    say "${C_DIM}  machine-id ${C_RESET}$DEMO_MID"
}

# =========================================================================
# CONFIG (saved per server on the flash drive)
# =========================================================================
load_config() {
    [ -r "$CONF_FILE" ] || return 0
    # shellcheck disable=SC1090
    . "$CONF_FILE" 2>/dev/null
}

save_config() {
    mkdir -p "$CONF_DIR" 2>/dev/null || { warn "cannot create $CONF_DIR"; return 1; }
    {
        echo "# saved by ${TOOL} v${VERSION} on $(date '+%F %T')"
        local x
        printf 'PATHS=('; for x in "${PATHS[@]:-}";       do [ -n "$x" ] && printf '%q ' "$x"; done; printf ')\n'
        printf 'EXCLUDES=('; for x in "${EXCLUDES[@]:-}";    do [ -n "$x" ] && printf '%q ' "$x"; done; printf ')\n'
        printf 'ALLOW_EXTRA=('; for x in "${ALLOW_EXTRA[@]:-}"; do [ -n "$x" ] && printf '%q ' "$x"; done; printf ')\n'
        echo "MIN_AGE=$MIN_AGE"; echo "DEEP=$DEEP"; echo "STRICT=$STRICT"
        printf 'WORK_DIR=%q\n' "$WORK_DIR"
    } >"$CONF_FILE" && ok "saved settings to $CONF_FILE"
}

# =========================================================================
# PATH RULES
# =========================================================================
# Prints a reason and returns 0 if the path must NOT be used; returns 1 if fine.
path_problem() {
    local r=$1
    [ -d "$r" ] || { echo "not a directory"; return 0; }
    case $r in
        /mnt/disk[0-9]*|/mnt/cache*|/mnt/user0*)
            echo "use the /mnt/user/... path (mixing disk and share paths risks data loss)"; return 0 ;;
        */appdata|*/appdata/*|/mnt/user/system*|/mnt/user/domains*|/mnt/user/isos*)
            echo "appdata/system folder — not a media library"; return 0 ;;
    esac
    [[ $r =~ ^/mnt/[^/]+/[^/]+ ]] || { echo "too broad — pick a folder inside a share"; return 0; }
    case "$r/" in "$WORK_DIR"/*) echo "that's this tool's own work folder"; return 0 ;; esac
    return 1
}

dedupe_paths() {
    local r k skip sorted=() keep=()
    mapfile -t sorted < <(printf '%s\n' "$@" | sed 's#/*$##' | sort -u)
    for r in "${sorted[@]}"; do
        [ -z "$r" ] && continue
        skip=0
        for k in "${keep[@]:-}"; do [ -n "$k" ] && [[ $r == "$k"/* ]] && skip=1; done
        (( skip )) || keep+=("$r")
    done
    PATHS=("${keep[@]:-}")
    [ -z "${PATHS[0]:-}" ] && PATHS=()
}

# =========================================================================
# DISCOVERY — which folders do Plex/Jellyfin/*arr actually use?
# =========================================================================
discover_load() {
    DET=()
    command -v docker >/dev/null 2>&1 || return 0
    local c src
    while read -r c; do
        [ -z "$c" ] && continue
        while read -r src; do
            [[ $src == /mnt/* ]] || continue
            [[ $src =~ /appdata|/system|/domains|/isos ]] && continue
            DET[$src]+="${DET[$src]:+,}$c"
        done < <(docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$c" 2>/dev/null)
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Ei "$MEDIA_CONTAINERS")
}

cmd_discover() {
    discover_load
    say "${C_BLU}${G_INFO} Folders mounted by Plex / Jellyfin / *arr containers${C_RESET}"
    local p any=0
    while IFS= read -r p; do
        any=1; printf '  %s %-44s %s<- %s%s\n' "$G_STAR" "$p" "$C_DIM" "${DET[$p]}" "$C_RESET"
        local d; for d in "$p"/*/; do [ -d "$d" ] && printf '        %s\n' "${d%/}"; done
    done < <(printf '%s\n' "${!DET[@]}" | sort)
    (( any )) || say "  (none found — is Docker running?)"
    say ""; say "${C_BLU}${G_INFO} User shares${C_RESET}"
    local d; for d in /mnt/user/*/; do [ -d "$d" ] && printf '  %s\n' "${d%/}"; done
    say ""
    say "${C_DIM}  Tip: pick the folders that hold FINISHED media (movies, tv, 4k-movies...),${C_RESET}"
    say "${C_DIM}  not the whole data share that also holds torrents/usenet downloads.${C_RESET}"
}

# =========================================================================
# DOCKER AUDIT — compatibility + exposure check for media containers
# =========================================================================
cmd_docker_audit() {
    command -v docker >/dev/null 2>&1 || die "docker not available"
    say "${C_BLU}${G_INFO} Container check${C_RESET}"
    local c line priv user env mounts m src dst rw ms
    while read -r c; do
        [ -z "$c" ] && continue
        line=$(docker inspect -f '{{.HostConfig.Privileged}}|{{.Config.User}}|{{range .Config.Env}}{{.}} {{end}}|{{range .Mounts}}{{.Source}}={{.Destination}}:{{if .RW}}rw{{else}}ro{{end}};{{end}}' "$c" 2>/dev/null) || continue
        priv=${line%%|*}; line=${line#*|}; user=${line%%|*}; line=${line#*|}; env=${line%%|*}; mounts=${line#*|}
        printf '\n  %s[%s]%s\n' "$C_BOLD" "$c" "$C_RESET"
        [ "$priv" = true ] && printf '    %s%s PRIVILEGED container — full host access if it is ever compromised%s\n' "$C_RED" "$G_WARN" "$C_RESET"
        local um pu pg
        um=$(grep -oE 'UMASK=[0-9]+' <<<"$env" | head -1); pu=$(grep -oE 'PUID=[0-9]+' <<<"$env" | head -1); pg=$(grep -oE 'PGID=[0-9]+' <<<"$env" | head -1)
        [ -n "$um$pu$pg" ] && printf '    %s%s %s %s%s\n' "$C_DIM" "${pu:-}" "${pg:-}" "${um:-}" "$C_RESET"
        IFS=';' read -r -a ms <<<"$mounts"
        for m in "${ms[@]}"; do
            [ -z "$m" ] && continue; [[ $m == /mnt/* ]] || continue
            src=${m%%=*}; dst=${m#*=}; rw=${dst##*:}; dst=${dst%:*}
            [[ $src =~ /appdata ]] && continue
            if [ "$rw" = rw ]; then
                if grep -Eqi 'plex|jellyfin|emby' <<<"$c"; then
                    printf '    %s%s%s RW media mount  %s %s %s   %s(players rarely need write — :ro is safe unless you store artwork/.nfo in media folders)%s\n' \
                        "$C_YEL" "$G_WARN" "$C_RESET" "$src" "$G_ARROW" "$dst" "$C_DIM" "$C_RESET"
                else
                    printf '    %s rw mount        %s %s %s\n' "$G_DOT" "$src" "$G_ARROW" "$dst"
                fi
            else
                printf '    %s%s%s ro mount        %s %s %s\n' "$C_GRN" "$G_OK" "$C_RESET" "$src" "$G_ARROW" "$dst"
            fi
        done
    done < <(docker ps -a --format '{{.Names}}' | grep -Ei "$MEDIA_CONTAINERS|$OTHER_CONTAINERS")
    say ""
}

# =========================================================================
# SCAN ENGINE
# =========================================================================
add_flag() { # root path sev why
    local root=$1 p=$2 sev=$3 why=$4 x
    for x in "${EXCLUDES[@]:-}"; do [ -n "$x" ] && [[ $p == "$root/$x"/* ]] && return 0; done
    ROOT_OF[$p]=$root
    (( sev > ${SEV[$p]:-0} )) && SEV[$p]=$sev
    [[ ${WHY[$p]:-} == *"$why"* ]] || WHY[$p]+="${WHY[$p]:+, }$why"
}

name_expr() { # -> NE array of "-iname *.ext -o ..." for the extensions given
    NE=(); local first=1 e
    for e in "$@"; do [ -n "$e" ] || continue; (( first )) || NE+=(-o); NE+=(-iname "*.$e"); first=0; done
}

magic_kind() {
    local h; h=$(od -An -N4 -tx1 -- "$1" 2>/dev/null | tr -d ' \n')
    case $h in
        7f454c46) echo "ELF-binary" ;;
        4d5a*)    echo "Windows-EXE" ;;
        2321*)    echo "script(#!)" ;;
        cafebabe) echo "Java/Mach-O" ;;
    esac
}

collect() {
    local root=$1 p k n
    local AGE=(-mmin "+$MIN_AGE") NE
    local allow=("${ALLOW_EXT[@]}" "${ALLOW_EXTRA[@]:-}")

    while IFS= read -r -d '' p; do add_flag "$root" "$p" 3 "setuid/setgid"; done \
        < <(find "$root" -type f "${AGE[@]}" -perm /6000 -print0 2>/dev/null)

    while IFS= read -r -d '' p; do add_flag "$root" "$p" 2 "exec-bit"; done \
        < <(find "$root" -type f "${AGE[@]}" -perm /111 -print0 2>/dev/null)

    name_expr "${DANGEROUS_EXT[@]}"
    while IFS= read -r -d '' p; do add_flag "$root" "$p" 3 "dangerous-extension"; done \
        < <(find "$root" -type f "${AGE[@]}" "(" "${NE[@]}" ")" -print0 2>/dev/null)

    name_expr "${ARCHIVE_EXT[@]}" 'r[0-9][0-9]'
    while IFS= read -r -d '' p; do add_flag "$root" "$p" 1 "archive/leftover"; done \
        < <(find "$root" -type f "${AGE[@]}" "(" "${NE[@]}" ")" -print0 2>/dev/null)

    # unknown = not allowed, not dangerous, not archive, not a benign name
    name_expr "${allow[@]}" "${DANGEROUS_EXT[@]}" "${ARCHIVE_EXT[@]}" 'r[0-9][0-9]'
    local UX=("${NE[@]}")
    for n in "${BENIGN_NAMES[@]}"; do UX+=(-o -name "$n"); done
    while IFS= read -r -d '' p; do add_flag "$root" "$p" 1 "unknown-extension"; done \
        < <(find "$root" -type f "${AGE[@]}" ! "(" "${UX[@]}" ")" -print0 2>/dev/null)

    while IFS= read -r -d '' p; do add_flag "$root" "$p" 1 "symlink"; done \
        < <(find "$root" -type l -print0 2>/dev/null)
    while IFS= read -r -d '' p; do add_flag "$root" "$p" 2 "special-file"; done \
        < <(find "$root" ! -type f ! -type d ! -type l -print0 2>/dev/null)

    if (( DEEP )); then
        name_expr "${allow[@]}"
        while IFS= read -r -d '' p; do
            k=$(magic_kind "$p")
            [ -n "$k" ] && add_flag "$root" "$p" 3 "disguised-$k"
        done < <(find "$root" -type f "${AGE[@]}" "(" "${NE[@]}" ")" -print0 2>/dev/null)
    fi
}

sev_label() { case $1 in 3) echo HIGH ;; 2) echo MED ;; *) echo REVIEW ;; esac; }
sev_color() { case $1 in 3) printf '%s' "$C_RED" ;; 2) printf '%s' "$C_YEL" ;; *) printf '%s' "$C_DIM" ;; esac; }

report() {
    local root p rel sub s key files
    local -A CNT=() SUBS=() TOT=()
    for p in "${!SEV[@]}"; do
        root=${ROOT_OF[$p]}; rel=${p#"$root"/}
        if [[ $rel == */* ]]; then sub=${rel%%/*}; else sub="(files in root)"; fi
        s=${SEV[$p]}
        CNT["$root|$sub|$s"]=$(( ${CNT["$root|$sub|$s"]:-0} + 1 ))
        SUBS["$root|$sub"]=1
        TOT[$s]=$(( ${TOT[$s]:-0} + 1 ))
    done

    local r
    for r in "${PATHS[@]}"; do
        files=$(find "$r" -type f -printf '.' 2>/dev/null | wc -c)
        log ""; log "${C_BOLD}${r}${C_RESET}  ${C_DIM}(${files} files scanned)${C_RESET}"
        local any=0
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            [[ $key == "$r|"* ]] || continue
            any=1; sub=${key#"$r|"}
            log "$(printf '  %-38s %sHIGH:%-4s%s %sMED:%-4s%s %sREVIEW:%-4s%s' "$sub" \
                "$C_RED" "${CNT["$r|$sub|3"]:-0}" "$C_RESET" "$C_YEL" "${CNT["$r|$sub|2"]:-0}" "$C_RESET" \
                "$C_DIM" "${CNT["$r|$sub|1"]:-0}" "$C_RESET")"
        done < <(printf '%s\n' "${!SUBS[@]}" | sort)
        (( any )) || ok "clean — nothing flagged"
    done

    log ""; log "${C_BLU}${G_INFO} findings${C_RESET}"
    local shown=0
    while IFS= read -r -d '' p; do
        [ -n "$p" ] || continue
        s=${SEV[$p]}
        if (( DETAIL || s >= 3 )); then
            log "$(printf '  %s[%-6s]%s %s' "$(sev_color "$s")" "$(sev_label "$s")" "$C_RESET" "$p")"
            log "             ${C_DIM}${WHY[$p]}${C_RESET}"
            shown=1
        fi
    done < <(printf '%s\0' "${!SEV[@]}" | sort -z)
    if (( ! shown )); then
        if (( ${#SEV[@]} )); then log "  ${C_DIM}no HIGH findings — use --detail to list MED/REVIEW${C_RESET}"
        else log "  none"; fi
    fi

    HIGH_COUNT=${TOT[3]:-0}; MED_COUNT=${TOT[2]:-0}; LOW_COUNT=${TOT[1]:-0}
    log ""
    log "  totals: ${C_RED}HIGH=${HIGH_COUNT}${C_RESET}  ${C_YEL}MED=${MED_COUNT}${C_RESET}  REVIEW=${LOW_COUNT}   ${C_DIM}(files modified in the last ${MIN_AGE} min are ignored)${C_RESET}"
}

# =========================================================================
# FIX — quarantine HIGH, strip exec bits on MED. Never deletes. Never touches
# write perms, ownership, directories, or files newer than MIN_AGE.
# =========================================================================
still_old_enough() { [ -n "$(find "$1" -maxdepth 0 -mmin "+$MIN_AGE" 2>/dev/null)" ]; }

apply_fix() {
    local p s why stamp dest manifest nq=0 nc=0 nerr=0 t
    stamp=$(date +%Y%m%d-%H%M%S)
    dest="$WORK_DIR/quarantine/$stamp"; manifest="$dest/MANIFEST.tsv"
    for p in "${!SEV[@]}"; do
        s=${SEV[$p]}; why=${WHY[$p]}
        [ -e "$p" ] || [ -L "$p" ] || continue
        still_old_enough "$p" || continue                    # upgrade/import started since the scan
        if (( s >= 3 )) || { (( STRICT )) && [[ $why == *unknown-extension* ]]; }; then
            [ -f "$p" ] && [ ! -L "$p" ] || continue
            t="$dest/${p#/mnt/}"
            mkdir -p -- "$(dirname -- "$t")" || { err "mkdir failed: $t"; nerr=$((nerr+1)); continue; }
            [ -e "$t" ] && t="$t.$RANDOM"
            if mv -- "$p" "$t"; then
                chmod a-x,u-s,g-s,go-rwx -- "$t" 2>/dev/null
                printf '%s\t%s\t%s\n' "$p" "$t" "$why" >>"$manifest"; nq=$((nq+1))
            else err "could not quarantine: $p"; nerr=$((nerr+1)); fi
        elif [[ $why == *exec-bit* || $why == *setuid* ]] && [ -f "$p" ] && [ ! -L "$p" ]; then
            if chmod a-x,u-s,g-s -- "$p"; then nc=$((nc+1)); else nerr=$((nerr+1)); fi
        fi
    done
    log ""
    ok "quarantined ${nq} file(s) · stripped exec bits on ${nc} file(s)"
    (( nq )) && log "  ${C_DIM}quarantine: ${dest}${C_RESET}" && \
        log "  ${C_DIM}undo:       $(self_path) --restore ${manifest}${C_RESET}"
    (( nerr )) && warn "${nerr} item(s) failed — see log"
    FIX_ERRORS=$nerr
    return 0
}
FIX_ERRORS=0

cmd_restore() {
    [ -r "$RESTORE_FILE" ] || die "usage: --restore /path/to/MANIFEST.tsv"
    local o t w n=0
    while IFS=$'\t' read -r o t w; do
        [ -e "$t" ] || continue
        [ -e "$o" ] && { warn "exists, skipping: $o"; continue; }
        mkdir -p -- "$(dirname -- "$o")" && mv -n -- "$t" "$o" && n=$((n+1))
    done <"$RESTORE_FILE"
    ok "restored ${n} file(s) — they stay non-executable (restore only if you're sure they're benign)"
}

cmd_list() {
    local d any=0
    for d in "$WORK_DIR"/quarantine/*/; do
        [ -f "${d}MANIFEST.tsv" ] || continue; any=1
        printf '  %s  %s files   %s\n' "$(basename "${d%/}")" "$(wc -l <"${d}MANIFEST.tsv")" "${d}MANIFEST.tsv"
    done
    (( any )) || say "  no quarantine batches yet"
}

# =========================================================================
# ENGINE RUN (shared by TUI, --scan, --fix)
# =========================================================================
run_engine() { # $1 = scan|fix
    local action=$1 bad p r
    mkdir -p "$WORK_DIR/logs" 2>/dev/null
    LOG_FILE="$WORK_DIR/logs/${action}-$(date +%Y%m%d-%H%M%S).log"; : >"$LOG_FILE" 2>/dev/null || LOG_FILE=""

    local valid=()
    for r in "${PATHS[@]:-}"; do
        [ -z "$r" ] && continue
        bad=$(path_problem "${r%/}") && { err "skipping $r — $bad"; continue; }
        valid+=("${r%/}")
    done
    (( ${#valid[@]} )) || die "no valid folders to check — pick some (TUI) or pass --path"
    dedupe_paths "${valid[@]}"

    log ""; log "${C_BLU}${G_INFO} ${action}${C_RESET}  ${C_DIM}deep=${DEEP} strict=${STRICT} min-age=${MIN_AGE}m${C_RESET}"
    for p in "${PATHS[@]}"; do
        log "  ${G_DOT} $p"
        local h
        for h in torrents usenet downloads incomplete complete; do
            [ -d "$p/$h" ] && ! printf '%s\n' "${EXCLUDES[@]:-}" | grep -qx "$h" \
                && warn "$p/$h exists under this folder — download dirs often hold archives/executables; consider excluding it"
        done
    done
    (( ${#EXCLUDES[@]} )) && [ -n "${EXCLUDES[0]:-}" ] && log "  ${C_DIM}excluding: ${EXCLUDES[*]}${C_RESET}"

    SEV=(); WHY=(); ROOT_OF=()
    for r in "${PATHS[@]}"; do collect "$r"; done
    report

    if [ "$action" = fix ]; then
        if (( ${#SEV[@]} == 0 )); then ok "nothing to fix"
        else
            if (( ! APPLY )); then
                if [ -t 0 ] && [ -t 1 ]; then
                    log ""
                    log "  ${C_BOLD}fix will:${C_RESET} quarantine ${HIGH_COUNT} HIGH item(s) (moved, never deleted) and strip exec bits on ${MED_COUNT} MED item(s)."
                    log "  ${C_DIM}It will NOT change write permissions, ownership, folders, or files newer than ${MIN_AGE} min —${C_RESET}"
                    log "  ${C_DIM}*arr upgrades/replacements and Plex/Jellyfin scans are unaffected.${C_RESET}"
                    local ans; read -rp "  Type YES to proceed: " ans
                    [ "$ans" = "YES" ] || { log "  aborted — nothing changed"; return 0; }
                else
                    die "--fix needs --apply when not interactive"
                fi
            fi
            apply_fix
        fi
    fi

    if (( NOTIFY && HIGH_COUNT > 0 )); then
        notify_unraid "${HIGH_COUNT} HIGH media finding(s)" \
            "${TOOL} ${action} flagged ${HIGH_COUNT} HIGH / ${MED_COUNT} MED item(s) in: ${PATHS[*]}. Log: ${LOG_FILE}" "warning"
    fi
    [ -n "$LOG_FILE" ] && say "  ${C_DIM}log: ${LOG_FILE}${C_RESET}"
    if [ "$action" = fix ] && (( FIX_ERRORS > 0 )); then return 3; fi
    (( HIGH_COUNT > 0 )) && [ "$action" = scan ] && return 2
    return 0
}

# =========================================================================
# TUI
# =========================================================================
tui_hide()  { [ -t 1 ] && printf '\033[?25l'; return 0; }
tui_show()  { [ -t 1 ] && printf '\033[?25h'; return 0; }
tui_clear() { printf '\033[2J\033[H'; }
tui_cleanup() { tui_show; }

read_key() { # sets KEY to: UP DOWN LEFT RIGHT ENTER SPACE BKSP ESC or the literal char
    local k rest
    IFS= read -rsn1 k 2>/dev/null || { KEY=ESC; return; }
    case "$k" in
        $'\033') read -rsn2 -t 0.05 rest 2>/dev/null
                 case "$rest" in '[A') KEY=UP ;; '[B') KEY=DOWN ;; '[C') KEY=RIGHT ;; '[D') KEY=LEFT ;; *) KEY=ESC ;; esac ;;
        ''|$'\n') KEY=ENTER ;;
        ' ')      KEY=SPACE ;;
        $'\177'|$'\b') KEY=BKSP ;;
        *)        KEY="$k" ;;
    esac
}

_row() {
    local stencil="$1" colored="$2"
    local n=$(( BOX_W + 2 - ${#stencil} )); [ $n -lt 0 ] && n=0
    printf '%s│%s%s%*s%s│%s\n' "$C_CYN" "$C_RESET" "$colored" "$n" "" "$C_CYN" "$C_RESET"
}
_hor() { printf '─%.0s' $(seq 1 $((BOX_W+2))); }
_fit() { local s=$1 max=$2; if [ ${#s} -gt "$max" ]; then printf '…%s' "${s: -$((max-1))}"; else printf '%s' "$s"; fi; }
row_kv() { # label value
    local v; v=$(_fit "$2" $((BOX_W - 16)))
    _row "$(printf '  %-10s  %s' "$1" "$v")" "$(printf '  %s%-10s%s  %s' "$C_BOLD" "$1" "$C_RESET" "$v")"
}
row_plain() { _row "  $1" "  $1"; }
row_dim()   { _row "  $1" "  ${C_DIM}$1${C_RESET}"; }

onoff() { [ "$1" = 1 ] && printf 'on' || printf 'off'; }

TUI_ACTION="scan"

draw_main() {
    local hor; hor=$(_hor)
    tui_clear
    printf '%s╭%s╮%s\n' "$C_CYN" "$hor" "$C_RESET"
    _row " ${TOOL} v${VERSION}  ·  interactive setup" "${C_BOLD} ${TOOL} v${VERSION}  ·  interactive setup${C_RESET}"
    printf '%s├%s┤%s\n' "$C_CYN" "$hor" "$C_RESET"
    row_kv "HOST" "${DEMO_HOST}  ·  Unraid ${DEMO_UNRAID}  ·  ${DEMO_RAM}"
    printf '%s├%s┤%s\n' "$C_CYN" "$hor" "$C_RESET"
    if (( ${#PATHS[@]} == 0 )); then
        row_kv "FOLDERS" "none selected — press p to pick"
    else
        local i=0 p
        for p in "${PATHS[@]}"; do
            i=$((i+1)); (( i > 6 )) && { row_kv "" "… +$(( ${#PATHS[@]} - 6 )) more"; break; }
            row_kv "$([ $i = 1 ] && echo FOLDERS || echo '')" "$p"
        done
    fi
    row_kv "SKIP" "$( [ -n "${EXCLUDES[0]:-}" ] && echo "${EXCLUDES[*]}" || echo '(none)')"
    printf '%s├%s┤%s\n' "$C_CYN" "$hor" "$C_RESET"
    if [ "$TUI_ACTION" = fix ]; then
        _row "  ACTION      FIX  (quarantine HIGH, strip exec bits)" \
             "  ${C_BOLD}ACTION${C_RESET}      ${C_YEL}FIX${C_RESET}  (quarantine HIGH, strip exec bits)"
    else
        row_kv "ACTION" "scan only — report, change nothing"
    fi
    row_kv "DEEP" "$(onoff $DEEP)  (peek inside media files: catches EXE renamed .mkv)"
    row_kv "STRICT" "$(onoff $STRICT)  (fix also quarantines unknown file types)"
    row_kv "MIN-AGE" "${MIN_AGE} min  (newer files never touched: upgrades safe)"
    printf '%s├%s┤%s\n' "$C_CYN" "$hor" "$C_RESET"
    row_dim "p pick folders   e skip-list   a action   d deep   s strict   m min-age"
    row_dim "w save settings  ENTER run     q quit"
    printf '%s╰%s╯%s\n' "$C_CYN" "$hor" "$C_RESET"
}

# Folder browser. ↑/↓ move · →/ENTER open · ←/BKSP up · SPACE select · c select this
# folder · g jump to detected media folders · t type a path · x clear · d done · q cancel
pick_paths_tui() {
    local cwd="/mnt/user" cursor=0 top=0 entries=() k i n win=14 bad
    local -A MARK=(); local p
    for p in "${PATHS[@]:-}"; do [ -n "$p" ] && MARK[$p]=1; done
    discover_load
    local det_list=(); mapfile -t det_list < <(printf '%s\n' "${!DET[@]}" | sort)
    local det_idx=-1 msg=""

    while :; do
        entries=(); local d
        for d in "$cwd"/*/; do [ -d "$d" ] && entries+=("${d%/}"); done
        n=${#entries[@]}
        (( cursor >= n )) && cursor=$(( n>0 ? n-1 : 0 ))
        (( cursor < top )) && top=$cursor
        (( cursor >= top+win )) && top=$(( cursor-win+1 ))

        local hor; hor=$(_hor)
        tui_clear
        printf '%s╭%s╮%s\n' "$C_CYN" "$hor" "$C_RESET"
        _row " pick folders to protect" "${C_BOLD} pick folders to protect${C_RESET}"
        row_kv "BROWSING" "$cwd"
        printf '%s├%s┤%s\n' "$C_CYN" "$hor" "$C_RESET"
        if (( n == 0 )); then row_dim "(no sub-folders here — press c to select this folder, ← to go up)"; fi
        for (( i=top; i<n && i<top+win; i++ )); do
            local e=${entries[$i]} mk="[ ]" tag="" cur=" "
            [ -n "${MARK[$e]:-}" ] && mk="[x]"
            [ -n "${DET[$e]:-}" ] && tag=" ${G_STAR} ${DET[$e]}"
            (( i == cursor )) && cur=">"
            local label; label=$(_fit "${e#"$cwd"/}${tag}" $((BOX_W - 12)))
            if (( i == cursor )); then
                _row "$(printf ' %s %s %s' "$cur" "$mk" "$label")" "$(printf ' %s%s %s %s%s' "$C_INV" "$cur" "$mk" "$label" "$C_RESET")"
            else
                _row "$(printf ' %s %s %s' "$cur" "$mk" "$label")" "$(printf ' %s %s%s%s %s' "$cur" "$([ "$mk" = "[x]" ] && printf '%s' "$C_GRN")" "$mk" "$C_RESET" "$label")"
            fi
        done
        printf '%s├%s┤%s\n' "$C_CYN" "$hor" "$C_RESET"
        row_kv "SELECTED" "${#MARK[@]} folder(s)"
        [ -n "$msg" ] && _row "  ! ${msg}" "  ${C_RED}! ${msg}${C_RESET}"
        row_dim "↑↓ move  → open  ← up  SPACE select  c select THIS folder"
        row_dim "g jump to Plex/*arr folders (${G_STAR})  t type path  x clear  d done  q cancel"
        printf '%s╰%s╯%s\n' "$C_CYN" "$hor" "$C_RESET"
        msg=""

        read_key
        case "$KEY" in
            UP)    (( cursor > 0 )) && cursor=$((cursor-1)) ;;
            DOWN)  (( cursor < n-1 )) && cursor=$((cursor+1)) ;;
            RIGHT|ENTER) (( n > 0 )) && { cwd=${entries[$cursor]}; cursor=0; top=0; } ;;
            LEFT|BKSP)   [ "$cwd" != "/mnt/user" ] && [ "$cwd" != "/mnt" ] && { cwd=$(dirname "$cwd"); cursor=0; top=0; } ;;
            SPACE|c)
                if [ "$KEY" = c ] || (( n == 0 )); then p=$cwd; else p=${entries[$cursor]}; fi
                if [ -n "${MARK[$p]:-}" ]; then unset 'MARK[$p]'
                elif bad=$(path_problem "$p"); then msg="blocked: ${bad}"
                else MARK[$p]=1; fi ;;
            g)  if (( ${#det_list[@]} )); then
                    det_idx=$(( (det_idx+1) % ${#det_list[@]} ))
                    cwd=$(dirname "${det_list[$det_idx]}"); cursor=0
                    local ents=(); for d in "$cwd"/*/; do [ -d "$d" ] && ents+=("${d%/}"); done
                    for (( i=0; i<${#ents[@]}; i++ )); do [ "${ents[$i]}" = "${det_list[$det_idx]}" ] && cursor=$i; done
                    top=$(( cursor > win-1 ? cursor-win+1 : 0 ))
                else msg="no Plex/*arr mounts detected"; fi ;;
            t)  tui_show; printf '\n  path: '; local typed; IFS= read -r typed; tui_hide
                typed=${typed%/}
                if [ -z "$typed" ]; then :
                elif bad=$(path_problem "$typed"); then msg="blocked: ${bad}"
                else MARK[$typed]=1; cwd=$(dirname "$typed"); fi ;;
            x)  MARK=() ;;
            d)  dedupe_paths "${!MARK[@]}"; return 0 ;;
            q|ESC) return 0 ;;
        esac
    done
}

setup_tui() {
    [ "$NO_TUI" = "1" ] && return 0
    [ -t 0 ] && [ -t 1 ] || return 0
    trap tui_cleanup EXIT
    tui_hide
    local typed
    while :; do
        draw_main
        read_key
        case "$KEY" in
            p) pick_paths_tui ;;
            e) tui_show; printf '\n  skip sub-folders (relative to each folder, space-separated; empty = none): '
               IFS= read -r typed; tui_hide
               read -r -a EXCLUDES <<<"$typed" ;;
            a) [ "$TUI_ACTION" = scan ] && TUI_ACTION=fix || TUI_ACTION=scan ;;
            d) DEEP=$((1-DEEP)) ;;
            s) STRICT=$((1-STRICT)) ;;
            m) case "$MIN_AGE" in 15) MIN_AGE=60 ;; 60) MIN_AGE=240 ;; 240) MIN_AGE=1440 ;; *) MIN_AGE=15 ;; esac ;;
            w) save_config >/dev/null ;;
            ENTER) tui_show; tui_clear
                   (( ${#PATHS[@]} )) && return 0
                   tui_hide ;;
            q|ESC) tui_show; tui_clear; printf 'cancelled\n'; exit 0 ;;
        esac
    done
}

# =========================================================================
# HANDOFF / USAGE / ARGS
# =========================================================================
handoff_to_terminal() {
    [ "${UNRAID_SCRIPTS_NO_HANDOFF:-0}" = "1" ] && return 0
    local self; self=$(self_path)
    printf '\n'
    printf '  ────────────────────────────────────────────────────────────\n'
    printf '  %s is interactive — you pick which media folders to check.\n' "$TOOL"
    printf '  A bare User Scripts click has no screen for that, so nothing ran.\n\n'
    printf '  Interactive (folder picker + review):\n'
    printf '    1. Open a terminal — Unraid webGUI  >_  icon, or SSH\n'
    printf '    2. Run:  bash %s\n\n' "$self"
    printf '  Scheduled / non-interactive (after saving folders once with w in the TUI):\n'
    printf '    --scan  --notify          report only, notify on HIGH findings\n'
    printf '    --scan  --deep --notify   also catch EXE/script renamed to .mkv\n'
    printf '    --fix   --apply           quarantine + strip exec bits (use with care)\n'
    printf '    --discover / --docker-audit / --list\n\n'
    printf '  To silence this handoff:  UNRAID_SCRIPTS_NO_HANDOFF=1\n'
    printf '  ────────────────────────────────────────────────────────────\n\n'
    notify_unraid "Open a terminal to pick media folders" \
        "$TOOL was launched from User Scripts with no flags. Open the Unraid terminal and run: bash $self — or schedule it with --scan --notify after saving folders once." "normal"
}

usage() {
    cat <<EOF
${TOOL} v${VERSION} — find and defuse executables hiding in your media library

Usage: $(basename "$0") [options]
  (no options, on a terminal)  interactive TUI: pick folders, review, run

Actions
  --scan                 report only (default for non-interactive use)
  --fix                  quarantine HIGH, strip exec bits on MED  (needs --apply when unattended)
  --discover             folders your Plex/Jellyfin/*arr containers use
  --docker-audit         privileged / read-write mount check on media containers
  --list                 quarantine batches
  --restore MANIFEST     move a quarantine batch back

Options
  --path DIR             folder to check (repeatable; overrides saved folders)
  --exclude REL          sub-folder to skip, relative to each --path (repeatable)
  --deep                 read first bytes of media files to catch disguised EXE/ELF/scripts
  --strict               with --fix, also quarantine unknown file types
  --allow EXT[,EXT]      extra extensions to treat as OK
  --min-age MIN          never flag/touch files modified in the last MIN minutes (default ${MIN_AGE})
  --detail               list every finding, not just HIGH
  --apply                don't prompt before --fix
  --notify               Unraid notification when HIGH findings exist
  --save                 save the folders/options as this server's defaults
  --work-dir DIR         logs + quarantine location (default ${WORK_DIR})
  --no-tui  --quiet
  --self-update  --check-update  --version  -h|--help

Safety: never deletes; never changes write permission, ownership or folder modes;
files newer than --min-age are skipped so *arr upgrades/imports are never interrupted.
Env: NO_COLOR=1  UNRAID_SCRIPTS_ASCII=1  UNRAID_SCRIPTS_NO_HANDOFF=1
Exit: 0 clean · 1 usage/config · 2 HIGH found (scan) · 3 fix had errors
EOF
}

parse_args() {
    local a
    while [ $# -gt 0 ]; do
        case "$1" in
            --scan)         MODE=scan ;;
            --fix)          MODE=fix ;;
            --discover)     MODE=discover ;;
            --docker-audit) MODE=docker ;;
            --list)         MODE=list ;;
            --restore)      MODE=restore; RESTORE_FILE="${2:-}"; shift ;;
            --path)         [ $# -ge 2 ] || die "--path needs a folder"; CLI_PATHS+=("${2%/}"); shift ;;
            --exclude)      [ $# -ge 2 ] || die "--exclude needs a name"; EXCLUDES+=("${2%/}"); shift ;;
            --deep)         DEEP=1 ;;
            --strict)       STRICT=1 ;;
            --allow)        [ $# -ge 2 ] || die "--allow needs a list"; IFS=, read -r -a a <<<"$2"; ALLOW_EXTRA+=("${a[@]}"); shift ;;
            --min-age)      [[ ${2:-} =~ ^[0-9]+$ ]] || die "--min-age needs a number"; MIN_AGE=$2; shift ;;
            --detail)       DETAIL=1 ;;
            --apply)        APPLY=1 ;;
            --notify)       NOTIFY=1 ;;
            --save)         SAVE=1 ;;
            --work-dir)     [ $# -ge 2 ] || die "--work-dir needs a folder"; WORK_DIR="${2%/}"; shift ;;
            --no-tui)       NO_TUI=1 ;;
            --quiet)        QUIET=1 ;;
            --self-update)  MODE=selfupdate ;;
            --check-update) MODE=checkupdate ;;
            --version)      MODE=version ;;
            -h|--help)      MODE=help ;;
            *) die "unknown argument: $1 (try --help)" ;;
        esac
        shift
    done
}

# ============================================================
# Brand mark — herbiewalker (inlined from DevPlaybook/templates/brand).
# Keep in sync with https://github.com/herbiewalker/DevPlaybook/tree/main/templates/brand
# Self-contained: doesn't depend on this script's palette.
# ============================================================
BRAND_SIGIL="⏣"
BRAND_MARK_SMALL="⏣ HW ⏣"
BRAND_TAGLINE="code · tools · homelab"

brand_banner_modern() {
    [ -t 1 ] || return 0
    local R="" C="" Y="" S="" B="" D=""
    if [ -z "${NO_COLOR:-}" ]; then
        R=$'\033[0m';  C=$'\033[36m'; Y=$'\033[33m'
        S=$'\033[32m'; B=$'\033[1m';  D=$'\033[2m'
    fi
    echo "${C}┌─────────────────────────────────────────────────────────────────┐${R}"
    echo "${C}│                                                                 │${R}"
    echo "${C}│    ${B}█ █    █ █${R}                                                   ${C}│${R}"
    echo "${C}│    ${B}█▀█    █▄█${R} ${Y}──●──●──${S}${BRAND_SIGIL}${R}   ${B}herbiewalker${R}                          ${C}│${R}"
    echo "${C}│    ${B}█ █    ▀ ▀${R}                        ${D}${BRAND_TAGLINE}${R}     ${C}│${R}"
    echo "${C}│                                                                 │${R}"
    echo "${C}└─────────────────────────────────────────────────────────────────┘${R}"
}

main() {
    local raw_argc=$#
    load_config
    parse_args "$@"

    case "$MODE" in
        help)        usage; exit 0 ;;
        version)     echo "${TOOL} v${VERSION}"; exit 0 ;;
        selfupdate)  self_update; exit $? ;;
        checkupdate) check_update; exit $? ;;
    esac

    demo_collect
    brand_banner_modern

    # Handoff: bare User Scripts click (no TTY + no args).
    if [ "$MODE" = "run" ] && { [ ! -t 0 ] || [ ! -t 1 ]; } && [ "$raw_argc" -eq 0 ]; then
        handoff_to_terminal; exit 0
    fi

    # CLI --path overrides saved folders for this run
    (( ${#CLI_PATHS[@]} )) && PATHS=("${CLI_PATHS[@]}")
    [ -n "${PATHS[0]:-}" ] || PATHS=()

    case "$MODE" in
        discover) cmd_discover; exit 0 ;;
        docker)   cmd_docker_audit; exit 0 ;;
        list)     cmd_list; exit 0 ;;
        restore)  cmd_restore; exit $? ;;
    esac

    if [ "$MODE" = "run" ]; then
        if [ -t 0 ] && [ -t 1 ] && [ "$NO_TUI" != "1" ]; then
            setup_tui; MODE=$TUI_ACTION
        else
            MODE=scan                      # non-interactive with only option flags = safe default
        fi
    fi

    (( SAVE )) && save_config
    demo_report
    run_engine "$MODE"
    exit $?
}

main "$@"

# ⏣ HW ⏣ · code · tools · homelab · ⏣ HW ⏣
