#!/bin/bash
# immich-backup v0.1.0
#
# Backs up Immich on Unraid via the safe path: stop stack -> rsync photos +
# tar appdata -> restart stack -> rotate. Self-contained, single file.
#
# LADDER STATUS: rung 5 climbed 2026-08-18 (425G rsync + trap-based stack
# restart both verified live on Unraid 7.3.1). Ongoing --preflight-only
# stays as the health check after any target-OS upgrade.
#
# Usage: script.sh [--preflight-only|--dry-run|--verify DIR|--restore DIR
#                   |--list|--help] [--dest PATH] [flags]
# See:   README.md, or `script.sh --help`
#
# Exit: 0 clean · 1 preflight · 2 backup failed · 3 STACK RESTART FAILED
#       4 verify/restore failed · 130 interrupted (stack still restarted)

set -uo pipefail
# set -e intentionally OFF: a phase must be able to fail without killing
# the cleanup trap that restarts the Immich stack.

VERSION="0.2.0"
TOOL="immich-backup"

# ---- self-update source (see --self-update / --check-update) --------------
UPDATE_REPO="herbiewalker/unraid-scripts"
UPDATE_BRANCH="main"
UPDATE_URL="https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}/${TOOL}/script.sh"

# --- defaults (overridable by flags; --dest is required for --run) --------
DEFAULT_SRC_PHOTOS="/mnt/user/immich/immich/photos"
DEFAULT_SRC_APPDATA="/mnt/user/appdata_immich"
DEFAULT_COMPOSE_DIR="/boot/config/plugins/compose.manager/projects/immich"
DEFAULT_DEST_ROOT="/mnt/user/data/backup_immich"
DEFAULT_KEEP_DAILY=7
DEFAULT_KEEP_WEEKLY=4
DEFAULT_KEEP_MONTHLY=6
DEFAULT_MIN_FREE_GB=50           # abort preflight if dest free < this

# --- flags ---------------------------------------------------------------
MODE="run"                # run | preflight | dry | verify | restore | list | remind | help
SRC_PHOTOS="$DEFAULT_SRC_PHOTOS"
SRC_APPDATA="$DEFAULT_SRC_APPDATA"
COMPOSE_DIR="$DEFAULT_COMPOSE_DIR"
DEST_ROOT=""
KEEP_DAILY="$DEFAULT_KEEP_DAILY"
KEEP_WEEKLY="$DEFAULT_KEEP_WEEKLY"
KEEP_MONTHLY="$DEFAULT_KEEP_MONTHLY"
DO_PHOTOS=1
DO_APPDATA=1
DO_COMPOSE=1
SKIP_STOP=0
QUIET=0
NO_TUI=0
CONFIRM=0
STRICT_SPACE=0            # do the slow accurate du-based check
MIN_FREE_GB="$DEFAULT_MIN_FREE_GB"
TARGET_DIR=""             # for --verify / --restore

# --- ANSI ----------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
    C_RED=$'\e[31m';   C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
    C_BLU=$'\e[34m';   C_CYN=$'\e[36m'; C_MAG=$'\e[35m'
else
    C_RESET=""; C_DIM=""; C_BOLD=""
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_MAG=""
fi

# --- state (populated during run) ----------------------------------------
STAMP=""                  # 20260818-1544
DEST_DIR=""               # ${DEST_ROOT}/${STAMP}
DEST_TMP=""               # ${DEST_ROOT}/.in-progress-${STAMP}
LOG_FILE=""
LOCKFILE="/var/lock/${TOOL}.lock"
STACK_WAS_STOPPED=0       # 1 if WE stopped it -> trap MUST restart
CONTAINERS=()             # discovered immich container names
DEMO_HOST=""; DEMO_MID=""; DEMO_UNRAID=""; DEMO_KERNEL=""
DEMO_CPU=""; DEMO_RAM=""; DEMO_BOARD=""; DEMO_UPTIME=""
BOX_W=76                  # TUI inner width

# =========================================================================
# LOGGING
# =========================================================================
log() {
    local msg="$*"
    if [ -n "$LOG_FILE" ]; then
        printf '%s %s\n' "$(date '+%F %T')" "$msg" >>"$LOG_FILE"
    fi
    [ "$QUIET" = "1" ] || printf '%s\n' "$msg"
}
say()   { [ "$QUIET" = "1" ] || printf '%s\n' "$*"; }
warn()  { log "  ${C_YEL}!${C_RESET} $*"; }
err()   { log "  ${C_RED}✗${C_RESET} $*" >&2; }
ok()    { log "  ${C_GRN}✓${C_RESET} $*"; }

notify_unraid() {
    local subj="$1" desc="$2" icon="${3:-normal}"
    [ -x /usr/local/emhttp/webGui/scripts/notify ] || return 0
    local h; h=$(hostname 2>/dev/null || echo unknown)
    /usr/local/emhttp/webGui/scripts/notify \
        -e "${TOOL}" -s "[$h] $subj" -d "$desc" -i "$icon" 2>/dev/null
    return 0
}

self_path() { local p="${BASH_SOURCE[0]:-$0}"; readlink -f "$p" 2>/dev/null || printf '%s' "$p"; }

_script_version_of() {
    grep -oE '^(SCRIPT_VERSION|VERSION)="[0-9]+\.[0-9]+\.[0-9]+"' "$1" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

check_update() {
    local tmp; tmp=$(mktemp 2>/dev/null) || tmp="/tmp/${TOOL}.check.$$"
    if ! curl -fsSL --max-time 15 "$UPDATE_URL" -o "$tmp" 2>/dev/null; then
        printf '  %s✗%s could not reach %s\n' "$C_YEL" "$C_RESET" "$UPDATE_URL"
        rm -f "$tmp"; return 1
    fi
    local remote; remote=$(_script_version_of "$tmp"); rm -f "$tmp"
    if [ -z "$remote" ]; then
        printf '  %s⚠%s remote fetched but version not parseable\n' "$C_YEL" "$C_RESET"
        return 1
    fi
    printf '  local:  %s\n' "$VERSION"
    printf '  remote: %s\n' "$remote"
    if [ "$VERSION" = "$remote" ]; then
        printf '  %s✓%s up to date\n' "$C_GRN" "$C_RESET"
    else
        printf '  %s▶%s new version available — run: %s --self-update\n' \
            "$C_YEL" "$C_RESET" "$(self_path)"
    fi
    return 0
}

self_update() {
    local target; target=$(self_path)
    if [ ! -w "$target" ] && [ ! -w "$(dirname "$target")" ]; then
        printf '  %s✗%s cannot write %s — need root\n' "$C_RED" "$C_RESET" "$target" >&2
        return 1
    fi
    local tmp; tmp=$(mktemp 2>/dev/null) || tmp="/tmp/${TOOL}.upd.$$"
    printf '  fetching %s ...\n' "$UPDATE_URL"
    if ! curl -fsSL --max-time 30 "$UPDATE_URL" -o "$tmp"; then
        printf '  %s✗%s fetch failed\n' "$C_RED" "$C_RESET" >&2
        rm -f "$tmp"; return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        printf '  %s✗%s downloaded file failed bash -n; keeping current copy\n' \
            "$C_RED" "$C_RESET" >&2
        rm -f "$tmp"; return 1
    fi
    local new_ver; new_ver=$(_script_version_of "$tmp")
    if [ -z "$new_ver" ]; then
        printf '  %s✗%s downloaded file has no parseable VERSION; refusing\n' \
            "$C_RED" "$C_RESET" >&2
        rm -f "$tmp"; return 1
    fi
    install -m 0755 "$tmp" "$target"
    rm -f "$tmp"
    printf '  %s✓%s updated: %s → %s  (%s)\n' \
        "$C_GRN" "$C_RESET" "$VERSION" "$new_ver" "$target"
    notify_unraid "Updated to v$new_ver" \
        "$TOOL updated from v$VERSION to v$new_ver via --self-update (source: $UPDATE_REPO@$UPDATE_BRANCH)." \
        "normal"
    return 0
}

# GUI → terminal handoff. Fires ONLY when MODE=="run" AND no TTY AND no args
# — a bare User Scripts click. --list / --remind / --preflight-only / --dry-run
# / --verify / --restore all set MODE≠run and thus bypass the handoff, so
# scheduled cron/User-Scripts jobs and read-only ops keep working non-
# interactively. Set UNRAID_SCRIPTS_NO_HANDOFF=1 to silence.
handoff_to_terminal() {
    [ "${UNRAID_SCRIPTS_NO_HANDOFF:-0}" = "1" ] && return 0
    local self cmd; self=$(self_path); cmd="bash $self --dest $DEST_ROOT"
    printf '\n'
    printf '  ────────────────────────────────────────────────────────────\n'
    printf '  immich-backup is about to STOP THE IMMICH STACK, back it up,\n'
    printf '  and restart it. That is not something to trigger by accident\n'
    printf '  from a bare User Scripts click.\n\n'
    printf '  To run it interactively (with the setup screen):\n'
    printf '    1. Open a terminal — Unraid webGUI  >_  icon, or SSH\n'
    printf '    2. Run:  %s\n\n' "$cmd"
    printf '  Non-interactive (User Scripts / cron / scheduled) — pass a flag:\n'
    printf '    --preflight-only    check the environment, touch nothing\n'
    printf '    --dry-run           print every action, touch nothing\n'
    printf '    --remind            fire the "last backup age" notification\n'
    printf '    --list              show existing backups\n'
    printf '    --dest PATH         run the backup (any flag bypasses handoff)\n\n'
    printf '  To silence this handoff:  UNRAID_SCRIPTS_NO_HANDOFF=1\n'
    printf '  ────────────────────────────────────────────────────────────\n\n'
    notify_unraid \
        "Open a terminal for the interactive setup" \
        "$TOOL was launched from User Scripts with no flags. Open the Unraid terminal (or SSH) and run: $cmd — or re-run with --preflight-only / --dry-run / --remind for a safe non-interactive mode." \
        "normal"
    return 0
}

# Interactive setup screen — review + confirm. Not a full editor (all fields
# have --flag equivalents); this is a "these are the settings I would run
# with, press ENTER to proceed or q to cancel" screen. Shown only for MODE=run
# with a real TTY and --no-tui not set.
#
# Width discipline (same rule as banner()): _row measures padding from the
# plain-ASCII STENCIL string, prints the COLOURED one. The two must have
# identical visual width — bold escapes add bytes but no glyphs.
_row() {
    local stencil="$1" colored="$2"
    local n=$(( BOX_W + 2 - ${#stencil} )); [ $n -lt 0 ] && n=0
    printf '%s│%s%s%*s%s│%s\n' \
        "$C_CYN" "$C_RESET" "$colored" "$n" "" "$C_CYN" "$C_RESET"
}
setup_tui() {
    [ "$NO_TUI" = "1" ] && return 0
    [ -t 0 ] && [ -t 1 ] || return 0
    local hor; hor=$(printf '─%.0s' $(seq 1 $((BOX_W+2))))
    local yn_p=$([ $DO_PHOTOS = 1 ] && echo yes || echo NO)
    local yn_a=$([ $DO_APPDATA = 1 ] && echo yes || echo NO)
    local yn_c=$([ $DO_COMPOSE = 1 ] && echo yes || echo NO)
    local strict=$([ $STRICT_SPACE = 1 ] && echo yes || echo no)
    local stack_stencil stack_colored
    if [ $SKIP_STOP = 1 ]; then
        stack_stencil="  STACK        will NOT STOP (--skip-stop set — inconsistent DB!)"
        stack_colored="  ${C_BOLD}STACK${C_RESET}        will ${C_RED}NOT STOP (--skip-stop set — inconsistent DB!)${C_RESET}"
    else
        stack_stencil="  STACK        will stop + restart via trap"
        stack_colored="  ${C_BOLD}STACK${C_RESET}        will stop + restart via trap"
    fi
    printf '\n%s╭%s╮%s\n' "$C_CYN" "$hor" "$C_RESET"
    _row " ${TOOL} v${VERSION}  ·  interactive setup" \
         "${C_BOLD} ${TOOL} v${VERSION}  ·  interactive setup${C_RESET}"
    printf '%s├%s┤%s\n' "$C_CYN" "$hor" "$C_RESET"
    _row "  HOST         ${DEMO_HOST}  ·  Unraid ${DEMO_UNRAID}  ·  ${DEMO_RAM}" \
         "  ${C_BOLD}HOST${C_RESET}         ${DEMO_HOST}  ·  Unraid ${DEMO_UNRAID}  ·  ${DEMO_RAM}"
    printf '%s├%s┤%s\n' "$C_CYN" "$hor" "$C_RESET"
    _row "  DEST         ${DEST_ROOT}" \
         "  ${C_BOLD}DEST${C_RESET}         ${DEST_ROOT}"
    _row "  SOURCES      photos=${SRC_PHOTOS}" \
         "  ${C_BOLD}SOURCES${C_RESET}      photos=${SRC_PHOTOS}"
    _row "               appdata=${SRC_APPDATA}" \
         "               appdata=${SRC_APPDATA}"
    _row "               compose=${COMPOSE_DIR}" \
         "               compose=${COMPOSE_DIR}"
    _row "  INCLUDE      photos=${yn_p}   appdata=${yn_a}   compose=${yn_c}" \
         "  ${C_BOLD}INCLUDE${C_RESET}      photos=${yn_p}   appdata=${yn_a}   compose=${yn_c}"
    _row "  RETENTION    daily=${KEEP_DAILY}   weekly=${KEEP_WEEKLY}   monthly=${KEEP_MONTHLY}" \
         "  ${C_BOLD}RETENTION${C_RESET}    daily=${KEEP_DAILY}   weekly=${KEEP_WEEKLY}   monthly=${KEEP_MONTHLY}"
    _row "  PREFLIGHT    min-free=${MIN_FREE_GB} GB   strict-space=${strict}" \
         "  ${C_BOLD}PREFLIGHT${C_RESET}    min-free=${MIN_FREE_GB} GB   strict-space=${strict}"
    _row "$stack_stencil" "$stack_colored"
    printf '%s├%s┤%s\n' "$C_CYN" "$hor" "$C_RESET"
    _row "  ENTER proceed   ·   q or ESC cancel   ·   changes: re-run with --flag" \
         "  ${C_DIM}ENTER proceed   ·   q or ESC cancel   ·   changes: re-run with --flag${C_RESET}"
    printf '%s╰%s╯%s\n\n' "$C_CYN" "$hor" "$C_RESET"

    local k _rest
    while :; do
        IFS= read -rsn1 k 2>/dev/null || return 0
        case "$k" in
            ''|$'\n')  return 0 ;;
            q|Q)       printf 'cancelled\n'; exit 0 ;;
            $'\033')   read -rsn2 -t 0.05 _rest 2>/dev/null; printf 'cancelled\n'; exit 0 ;;
        esac
    done
}

# =========================================================================
# ARGS
# =========================================================================
usage() {
    cat <<EOF
${TOOL} v${VERSION}  -  Immich backup for Unraid

USAGE
  script.sh --preflight-only        # rung 3 of the ladder (first live run)
  script.sh --dry-run [--dest PATH] # rung 2: print every action, touch nothing
  script.sh --dest PATH [flags]     # rung 4/5: real backup
  script.sh --list [--dest PATH]    # table of existing backups + retention class
  script.sh --remind                # fire Unraid notification with last-backup age
                                    # + the command to run — no backup work
  script.sh --verify PATH           # untar into scratch, check sha256s
  script.sh --restore PATH --confirm  # DANGEROUS: stops stack + replaces data
  script.sh --help

BACKUP FLAGS
  --dest PATH             backup destination root (default: ${DEFAULT_DEST_ROOT})
  --src-photos PATH       photos source (default: ${DEFAULT_SRC_PHOTOS})
  --src-appdata PATH      appdata source (default: ${DEFAULT_SRC_APPDATA})
  --compose-dir PATH      docker-compose dir (default: ${DEFAULT_COMPOSE_DIR})
  --skip-photos           don't back up the photo library
  --skip-appdata          don't back up postgres/redis/config appdata
  --skip-compose          don't back up the compose file + .env
  --skip-stop             DANGEROUS: don't stop the stack (inconsistent DB!)
  --keep-daily N          retention: daily backups (default: ${DEFAULT_KEEP_DAILY})
  --keep-weekly N         retention: weekly backups (default: ${DEFAULT_KEEP_WEEKLY})
  --keep-monthly N        retention: monthly backups (default: ${DEFAULT_KEEP_MONTHLY})
  --quiet                 minimal output (for cron / User Scripts)
  --no-tui                plain output only
  --min-free-gb N         preflight aborts if dest free < N GB (default: ${DEFAULT_MIN_FREE_GB})
  --strict-space          also do the slow \`du -sx\` accurate source-size check
                          (default: fast df-based free-space check only)

EXIT CODES
  0   clean
  1   preflight failed - nothing was touched
  2   backup failed - stack was restarted, partial backup marked FAILED
  3   ${C_RED}STACK RESTART FAILED${C_RESET} - Immich may still be stopped, investigate now
  4   verify or restore failed
  130 interrupted (Ctrl-C) - stack was still restarted by trap

FIRST RUN ON A REAL TARGET
  Always staged. Never start at full scope:
    script.sh --preflight-only              # environment checks, acts on nothing
    script.sh --dry-run --dest /mnt/.../    # shows what it WOULD do
    script.sh --dest /mnt/.../ --skip-photos --keep-daily 2  # tiny live scope
    script.sh --dest /mnt/.../              # full backup
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --preflight-only) MODE="preflight" ;;
            --dry-run)        MODE="dry" ;;
            --list)           MODE="list" ;;
            --remind)         MODE="remind" ;;
            --verify)         MODE="verify"; TARGET_DIR="${2:-}"; shift ;;
            --restore)        MODE="restore"; TARGET_DIR="${2:-}"; shift ;;
            --help|-h)        MODE="help" ;;
            --dest)           DEST_ROOT="${2:-}"; shift ;;
            --src-photos)     SRC_PHOTOS="${2:-}"; shift ;;
            --src-appdata)    SRC_APPDATA="${2:-}"; shift ;;
            --compose-dir)    COMPOSE_DIR="${2:-}"; shift ;;
            --skip-photos)    DO_PHOTOS=0 ;;
            --skip-appdata)   DO_APPDATA=0 ;;
            --skip-compose)   DO_COMPOSE=0 ;;
            --skip-stop)      SKIP_STOP=1 ;;
            --keep-daily)     KEEP_DAILY="${2:-}"; shift ;;
            --keep-weekly)    KEEP_WEEKLY="${2:-}"; shift ;;
            --keep-monthly)   KEEP_MONTHLY="${2:-}"; shift ;;
            --quiet)          QUIET=1 ;;
            --no-tui)         NO_TUI=1 ;;
            --confirm)        CONFIRM=1 ;;
            --strict-space)   STRICT_SPACE=1 ;;
            --min-free-gb)    MIN_FREE_GB="${2:-}"; shift ;;
            --self-update)    self_update;  exit $? ;;
            --check-update)   check_update; exit $? ;;
            --version)        echo "${TOOL} v${VERSION}"; exit 0 ;;
            *) err "unknown flag: $1"; usage >&2; exit 1 ;;
        esac
        shift
    done
    [ -z "$DEST_ROOT" ] && DEST_ROOT="$DEFAULT_DEST_ROOT"
}

# =========================================================================
# TUI
# =========================================================================
_pad() { local s="$1" w="$2"; local n=$(( w - ${#s} )); [ $n -lt 0 ] && n=0; printf '%s%*s' "$s" "$n" ''; }

banner() {
    [ "$QUIET" = "1" ] && return
    local title="$1"
    local top="╭" mid="├" bot="╰"
    local hor line
    hor=$(printf '─%.0s' $(seq 1 $((BOX_W+2))))
    say "${C_CYN}${top}${hor}${top:+╮}${C_RESET}"
    line=$(printf ' %s v%s  ·  %s' "$TOOL" "$VERSION" "$title")
    say "${C_CYN}│${C_RESET}${C_BOLD}$(_pad "$line" $((BOX_W+2)))${C_RESET}${C_CYN}│${C_RESET}"
    say "${C_CYN}${mid}${hor}${mid:+┤}${C_RESET}"
}

banner_close() {
    [ "$QUIET" = "1" ] && return
    local hor
    hor=$(printf '─%.0s' $(seq 1 $((BOX_W+2))))
    say "${C_CYN}╰${hor}╯${C_RESET}"
}

phase_head() {
    [ "$QUIET" = "1" ] && return
    say ""
    say "${C_BLU}▶ $*${C_RESET}"
    say "${C_DIM}$(printf '─%.0s' $(seq 1 $BOX_W))${C_RESET}"
}

status_line() {
    [ "$QUIET" = "1" ] && return
    local kind="$1"; shift
    local sym color
    case "$kind" in
        ok)   sym="✓"; color="$C_GRN" ;;
        warn) sym="!"; color="$C_YEL" ;;
        fail) sym="✗"; color="$C_RED" ;;
        info) sym="·"; color="$C_DIM" ;;
        *)    sym="·"; color="" ;;
    esac
    printf '  %s%s%s %s\n' "$color" "$sym" "$C_RESET" "$*"
}

# =========================================================================
# DEMOGRAPHICS (safe set — matches hardware-stress-test & DeepScan)
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
    local ram_kb
    ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$ram_kb" ]; then
        DEMO_RAM="$(( ram_kb / 1024 / 1024 )) GB"
    else
        DEMO_RAM="unknown"
    fi
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
# PREFLIGHT
# =========================================================================
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "must run as root (sudo)"
        return 1
    fi
    return 0
}

check_deps() {
    local missing=""
    for cmd in docker rsync tar sha256sum awk sed date df du find sort head tail; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        err "missing dependencies:$missing"
        return 1
    fi
    return 0
}

check_paths() {
    local ok_all=1
    if [ "$DO_PHOTOS" = "1" ] && [ ! -d "$SRC_PHOTOS" ]; then
        err "photos source not found: $SRC_PHOTOS"
        ok_all=0
    fi
    if [ "$DO_APPDATA" = "1" ] && [ ! -d "$SRC_APPDATA" ]; then
        err "appdata source not found: $SRC_APPDATA"
        ok_all=0
    fi
    if [ "$DO_COMPOSE" = "1" ] && [ ! -d "$COMPOSE_DIR" ]; then
        warn "compose dir not found: $COMPOSE_DIR (will skip compose snapshot)"
    fi
    [ $ok_all -eq 1 ]
}

check_dest() {
    if [ ! -d "$DEST_ROOT" ]; then
        local parent
        parent="$(dirname "$DEST_ROOT")"
        if [ ! -d "$parent" ]; then
            err "dest parent does not exist: $parent"
            return 1
        fi
        local probe="$parent/.write-test-$$"
        if ! touch "$probe" 2>/dev/null; then
            err "dest parent not writable: $parent"
            return 1
        fi
        rm -f "$probe"
        if [ "$MODE" = "preflight" ] || [ "$MODE" = "dry" ]; then
            warn "dest root does not exist yet: $DEST_ROOT (parent $parent is writable, would create)"
            return 0
        fi
        say "  creating dest root: $DEST_ROOT"
        mkdir -p "$DEST_ROOT" || { err "cannot create $DEST_ROOT"; return 1; }
    fi
    local testfile="$DEST_ROOT/.write-test-$$"
    if ! touch "$testfile" 2>/dev/null; then
        err "dest root not writable: $DEST_ROOT"
        return 1
    fi
    rm -f "$testfile"
    return 0
}

check_free_space() {
    # Fast path: df on dest, guardrail on absolute free space.  A dest that
    # doesn't exist yet gets its parent probed (df walks up automatically).
    local probe_path="$DEST_ROOT"
    [ ! -d "$probe_path" ] && probe_path="$(dirname "$DEST_ROOT")"
    local free_kb
    free_kb=$(df -Pk "$probe_path" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$free_kb" ]; then
        warn "could not read df on $probe_path"
        return 0
    fi
    local free_gb=$(( free_kb / 1024 / 1024 ))
    if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
        err "dest free ${free_gb}G < minimum ${MIN_FREE_GB}G (--min-free-gb to override)"
        return 1
    fi

    if [ "$STRICT_SPACE" = "1" ]; then
        # Slow path: du -sx across sources.  Only when the user asks — a 400G+
        # photo library can take minutes to stat.
        say "  (--strict-space: measuring sources — this may take several minutes)"
        local need_kb=0 photos_kb appd_kb
        if [ "$DO_PHOTOS" = "1" ] && [ -d "$SRC_PHOTOS" ]; then
            photos_kb=$(du -sxk "$SRC_PHOTOS" 2>/dev/null | awk '{print $1}')
            need_kb=$(( need_kb + ${photos_kb:-0} ))
        fi
        if [ "$DO_APPDATA" = "1" ] && [ -d "$SRC_APPDATA" ]; then
            appd_kb=$(du -sxk "$SRC_APPDATA" 2>/dev/null | awk '{print $1}')
            need_kb=$(( need_kb + appd_kb + appd_kb / 10 ))
        fi
        local need_gb=$(( need_kb / 1024 / 1024 ))
        if [ "$need_kb" -gt "$free_kb" ]; then
            err "not enough free space: need ~${need_gb}G, have ${free_gb}G"
            return 1
        fi
        status_line info "space:  need ~${need_gb}G  ·  free ${free_gb}G on $probe_path"
    else
        status_line info "space:  free ${free_gb}G on $probe_path  (--strict-space for source measure)"
    fi
    return 0
}

check_lockfile() {
    if [ -e "$LOCKFILE" ]; then
        local pid
        pid=$(cat "$LOCKFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            err "another $TOOL is running (pid $pid, lockfile $LOCKFILE)"
            return 1
        fi
        warn "stale lockfile removed: $LOCKFILE"
        rm -f "$LOCKFILE"
    fi
    return 0
}

discover_containers() {
    if ! command -v docker >/dev/null 2>&1; then
        CONTAINERS=()
        return 1
    fi
    mapfile -t CONTAINERS < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE '^immich' || true)
    if [ "${#CONTAINERS[@]}" -eq 0 ]; then
        warn "no running immich-* containers found"
        return 1
    fi
    return 0
}

preflight() {
    phase_head "Preflight"
    local ok_all=1

    require_root       && status_line ok "root"                     || { status_line fail "not root - run with sudo";      ok_all=0; }
    check_deps         && status_line ok "core deps present"        || ok_all=0
    check_paths        && status_line ok "sources present"          || ok_all=0
    check_dest         && status_line ok "dest writable"            || ok_all=0
    check_lockfile     && status_line ok "no other backup running"  || ok_all=0
    if discover_containers; then
        status_line ok "immich containers detected: ${CONTAINERS[*]}"
    else
        status_line warn "docker not usable or no immich containers"
    fi
    if [ "$MODE" != "preflight" ]; then
        check_free_space || ok_all=0
    else
        check_free_space || true
    fi

    [ $ok_all -eq 1 ]
}

# =========================================================================
# STACK CONTROL  (with the critical restart guarantee)
# =========================================================================
stop_stack() {
    [ "$SKIP_STOP" = "1" ] && { warn "skipping stack stop (--skip-stop)"; return 0; }
    phase_head "Stopping Immich stack"
    if [ "$MODE" = "dry" ]; then
        for c in "${CONTAINERS[@]}"; do status_line info "would: docker stop $c"; done
        return 0
    fi
    STACK_WAS_STOPPED=1
    local failed=""
    for c in "${CONTAINERS[@]}"; do
        if docker stop "$c" >>"$LOG_FILE" 2>&1; then
            status_line ok "stopped $c"
        else
            status_line fail "docker stop $c failed"
            failed="$failed $c"
        fi
    done
    if [ -n "$failed" ]; then
        err "failed to stop:$failed"
        return 1
    fi
    return 0
}

start_stack() {
    [ "$STACK_WAS_STOPPED" = "0" ] && return 0
    phase_head "Restarting Immich stack"
    if [ "$MODE" = "dry" ]; then
        for c in "${CONTAINERS[@]}"; do status_line info "would: docker start $c"; done
        return 0
    fi
    local failed=""
    for c in "${CONTAINERS[@]}"; do
        if docker start "$c" >>"$LOG_FILE" 2>&1; then
            status_line ok "started $c"
        else
            status_line fail "docker start $c FAILED - investigate immediately"
            failed="$failed $c"
        fi
    done
    if [ -n "$failed" ]; then
        err "CRITICAL: failed to restart:$failed"
        return 1
    fi
    STACK_WAS_STOPPED=0
    return 0
}

# =========================================================================
# BACKUP PHASES
# =========================================================================
backup_photos() {
    [ "$DO_PHOTOS" = "0" ] && { say "  (skipped: --skip-photos)"; return 0; }
    phase_head "Photos:  $SRC_PHOTOS  →  $DEST_TMP/photos/"
    if [ "$MODE" = "dry" ]; then
        status_line info "would: rsync -aHAX --info=progress2 '$SRC_PHOTOS/' '$DEST_TMP/photos/'"
        return 0
    fi
    mkdir -p "$DEST_TMP/photos"
    local rsync_flags="-aHAX --delete --numeric-ids"
    [ "$QUIET" = "1" ] || rsync_flags="$rsync_flags --info=progress2"
    # shellcheck disable=SC2086
    rsync $rsync_flags "$SRC_PHOTOS/" "$DEST_TMP/photos/" 2>>"$LOG_FILE"
    local rc=$?
    if [ $rc -eq 0 ]; then
        ok "photos synced"
    else
        err "rsync exited $rc"
        return 1
    fi
    return 0
}

backup_appdata() {
    [ "$DO_APPDATA" = "0" ] && { say "  (skipped: --skip-appdata)"; return 0; }
    phase_head "Appdata: $SRC_APPDATA  →  $DEST_TMP/appdata.tar.gz"
    if [ "$MODE" = "dry" ]; then
        status_line info "would: tar czf '$DEST_TMP/appdata.tar.gz' -C '$(dirname "$SRC_APPDATA")' '$(basename "$SRC_APPDATA")'"
        return 0
    fi
    local base parent
    parent="$(dirname "$SRC_APPDATA")"
    base="$(basename "$SRC_APPDATA")"
    tar czf "$DEST_TMP/appdata.tar.gz" -C "$parent" "$base" 2>>"$LOG_FILE"
    local rc=$?
    if [ $rc -eq 0 ]; then
        ok "appdata archived"
    else
        err "tar exited $rc"
        return 1
    fi
    return 0
}

backup_compose() {
    [ "$DO_COMPOSE" = "0" ] && { say "  (skipped: --skip-compose)"; return 0; }
    [ ! -d "$COMPOSE_DIR" ] && { warn "compose dir absent, skipping"; return 0; }
    phase_head "Compose: $COMPOSE_DIR  →  $DEST_TMP/compose/"
    if [ "$MODE" = "dry" ]; then
        status_line info "would: cp -a '$COMPOSE_DIR' '$DEST_TMP/compose'"
        return 0
    fi
    cp -a "$COMPOSE_DIR" "$DEST_TMP/compose" 2>>"$LOG_FILE"
    local rc=$?
    if [ $rc -eq 0 ]; then
        ok "compose captured"
    else
        err "cp exited $rc"
        return 1
    fi
    return 0
}

write_manifest() {
    local manifest="$DEST_TMP/manifest.json"
    [ "$MODE" = "dry" ] && { status_line info "would: write manifest.json"; return 0; }
    local photo_bytes=0 appd_bytes=0 photo_sha="" appd_sha=""
    if [ -d "$DEST_TMP/photos" ]; then
        photo_bytes=$(du -sxb "$DEST_TMP/photos" 2>/dev/null | awk '{print $1}')
    fi
    if [ -f "$DEST_TMP/appdata.tar.gz" ]; then
        appd_bytes=$(stat -c '%s' "$DEST_TMP/appdata.tar.gz" 2>/dev/null || echo 0)
        appd_sha=$(sha256sum "$DEST_TMP/appdata.tar.gz" 2>/dev/null | awk '{print $1}')
    fi
    cat >"$manifest" <<EOF
{
  "tool": "${TOOL}",
  "version": "${VERSION}",
  "stamp": "${STAMP}",
  "host": "${DEMO_HOST}",
  "machine_id": "${DEMO_MID}",
  "unraid": "${DEMO_UNRAID}",
  "kernel": "${DEMO_KERNEL}",
  "board": "${DEMO_BOARD}",
  "cpu": "${DEMO_CPU}",
  "ram": "${DEMO_RAM}",
  "components": {
    "photos":  { "included": $( [ "$DO_PHOTOS"  = "1" ] && echo true || echo false ), "bytes": ${photo_bytes:-0} },
    "appdata": { "included": $( [ "$DO_APPDATA" = "1" ] && echo true || echo false ), "bytes": ${appd_bytes:-0}, "sha256": "${appd_sha}" },
    "compose": { "included": $( [ "$DO_COMPOSE" = "1" ] && echo true || echo false ) }
  },
  "sources": {
    "photos":  "${SRC_PHOTOS}",
    "appdata": "${SRC_APPDATA}",
    "compose": "${COMPOSE_DIR}"
  }
}
EOF
    ok "manifest written"
}

# =========================================================================
# GFS RETENTION
# =========================================================================
rotate() {
    phase_head "Retention: keep ${KEEP_DAILY}d / ${KEEP_WEEKLY}w / ${KEEP_MONTHLY}m"
    if [ ! -d "$DEST_ROOT" ]; then
        status_line info "no dest dir yet, nothing to rotate"
        return 0
    fi
    local now_epoch today_wday
    now_epoch=$(date +%s)
    today_wday=$(date +%u)  # 1..7 Mon..Sun
    # We keep: last N daily, last M Sundays (weekly), last K first-of-month (monthly).
    local dailies=() weeklies=() monthlies=() prune=()
    local all=()
    mapfile -t all < <(find "$DEST_ROOT" -maxdepth 1 -mindepth 1 -type d -name '20*-*' -printf '%f\n' 2>/dev/null | sort)
    for name in "${all[@]}"; do
        # name = YYYYMMDD-HHMM
        local day="${name%-*}"
        local ymd="${day:0:8}"
        local yyyy="${ymd:0:4}" mm="${ymd:4:2}" dd="${ymd:6:2}"
        local epoch wday dom
        epoch=$(date -d "$yyyy-$mm-$dd" +%s 2>/dev/null || echo 0)
        wday=$(date -d "$yyyy-$mm-$dd" +%u 2>/dev/null || echo 0)
        dom=$(( 10#$dd ))
        dailies+=("$name")
        [ "$wday" = "7" ] && weeklies+=("$name")
        [ "$dom" = "1" ]  && monthlies+=("$name")
    done
    # keep = last N of each; anything not in any keep-set is pruned
    local keep_set=""
    _tail_set() {
        local n="$1"; shift
        local arr=("$@")
        local start=$(( ${#arr[@]} - n ))
        [ $start -lt 0 ] && start=0
        printf '%s\n' "${arr[@]:$start}"
    }
    keep_set="$(_tail_set "$KEEP_DAILY" "${dailies[@]}" 2>/dev/null)
$(_tail_set "$KEEP_WEEKLY" "${weeklies[@]}" 2>/dev/null)
$(_tail_set "$KEEP_MONTHLY" "${monthlies[@]}" 2>/dev/null)"
    for name in "${all[@]}"; do
        if ! grep -qxF "$name" <<<"$keep_set"; then
            prune+=("$name")
        fi
    done
    if [ "${#prune[@]}" -eq 0 ]; then
        status_line ok "nothing to prune"
        return 0
    fi
    for name in "${prune[@]}"; do
        if [ "$MODE" = "dry" ]; then
            status_line info "would prune: $name"
        else
            rm -rf "${DEST_ROOT:?}/${name}" && status_line ok "pruned $name" || status_line fail "could not prune $name"
        fi
    done
}

# =========================================================================
# LIST / VERIFY / RESTORE
# =========================================================================
list_backups() {
    banner "list backups in $DEST_ROOT"
    if [ ! -d "$DEST_ROOT" ]; then
        warn "dest root not found: $DEST_ROOT"
        banner_close
        return 0
    fi
    printf '  %-18s %10s  %s\n' "STAMP" "SIZE" "COMPONENTS"
    printf '  %-18s %10s  %s\n' "------------------" "----------" "------------------------"
    local d
    for d in "$DEST_ROOT"/20*-*; do
        [ -d "$d" ] || continue
        local name size comp="" mani="$d/manifest.json"
        name="$(basename "$d")"
        size="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
        [ -d "$d/photos" ]        && comp="${comp}photos "
        [ -f "$d/appdata.tar.gz" ] && comp="${comp}appdata "
        [ -d "$d/compose" ]       && comp="${comp}compose "
        [ -f "$d/FAILED" ]        && comp="${C_RED}${comp}(FAILED)${C_RESET}"
        [ -f "$mani" ]            || comp="${comp}${C_YEL}(no manifest)${C_RESET}"
        printf '  %-18s %10s  %s\n' "$name" "$size" "$comp"
    done
    banner_close
}

verify_backup() {
    banner "verify $TARGET_DIR"
    [ -z "$TARGET_DIR" ] && { err "--verify requires a path"; return 1; }
    [ ! -d "$TARGET_DIR" ] && { err "not a directory: $TARGET_DIR"; return 1; }
    local mani="$TARGET_DIR/manifest.json" ok_all=1
    if [ ! -f "$mani" ]; then
        err "no manifest.json in $TARGET_DIR"
        return 1
    fi
    if [ -f "$TARGET_DIR/appdata.tar.gz" ]; then
        local want got
        want=$(grep -oE '"sha256"[^"]*"[^"]*"' "$mani" | head -1 | awk -F'"' '{print $4}')
        got=$(sha256sum "$TARGET_DIR/appdata.tar.gz" | awk '{print $1}')
        if [ -n "$want" ] && [ "$want" = "$got" ]; then
            status_line ok "appdata sha256 matches"
        else
            status_line fail "appdata sha256 mismatch"
            ok_all=0
        fi
        if tar tzf "$TARGET_DIR/appdata.tar.gz" >/dev/null 2>&1; then
            status_line ok "appdata tarball readable"
        else
            status_line fail "appdata tarball unreadable"
            ok_all=0
        fi
    fi
    if [ -d "$TARGET_DIR/photos" ]; then
        local pcount
        pcount=$(find "$TARGET_DIR/photos" -type f 2>/dev/null | wc -l)
        status_line info "photos: $pcount files present"
    fi
    banner_close
    [ $ok_all -eq 1 ]
}

remind() {
    banner "reminder  ·  no backup work"
    local latest="" latest_epoch now_epoch days_since=""
    if [ -d "$DEST_ROOT" ]; then
        latest=$(find "$DEST_ROOT" -maxdepth 1 -mindepth 1 -type d -name '20*-*' -printf '%f\n' 2>/dev/null | sort | tail -1)
    fi
    now_epoch=$(date +%s)
    local self="/boot/config/plugins/user.scripts/scripts/immich-backup/script"
    local subj desc icon
    if [ -z "$latest" ]; then
        subj="immich-backup: no backup found"
        desc="No Immich backup found in ${DEST_ROOT}. Run it now: bash ${self}"
        icon="warning"
        status_line warn "$desc"
    else
        latest_epoch=$(date -d "${latest:0:4}-${latest:4:2}-${latest:6:2}" +%s 2>/dev/null)
        if [ -n "$latest_epoch" ]; then
            days_since=$(( (now_epoch - latest_epoch) / 86400 ))
        fi
        if [ -n "$days_since" ] && [ "$days_since" -ge 30 ]; then
            icon="warning"
        else
            icon="normal"
        fi
        subj="immich-backup: last run ${days_since:-?} days ago"
        desc="Last backup: ${latest} (${days_since:-?} days ago). Command to run a new one: bash ${self}"
        status_line info "$desc"
    fi
    notify_unraid "$subj" "$desc" "$icon"
    banner_close
    return 0
}

restore_backup() {
    banner "RESTORE from $TARGET_DIR"
    [ -z "$TARGET_DIR" ]        && { err "--restore requires a path"; return 1; }
    [ ! -d "$TARGET_DIR" ]      && { err "not a directory: $TARGET_DIR"; return 1; }
    [ "$CONFIRM" != "1" ]       && { err "--restore requires --confirm (this is destructive)"; return 1; }
    warn "restore is stubbed in v${VERSION} — refusing to overwrite live data"
    warn "planned in v0.2 after --run has a green live-target run"
    return 4
}

# =========================================================================
# TRAP: the critical restart guarantee
# =========================================================================
cleanup_trap() {
    local rc=$?
    trap - EXIT INT TERM
    # remove lockfile if we own it
    if [ -e "$LOCKFILE" ] && [ "$(cat "$LOCKFILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$LOCKFILE"
    fi
    # mark partial backup FAILED, don't leave it looking clean
    if [ -n "$DEST_TMP" ] && [ -d "$DEST_TMP" ]; then
        touch "$DEST_TMP/FAILED" 2>/dev/null
        warn "left partial backup as ${DEST_TMP}/FAILED"
    fi
    # RESTART THE STACK if we stopped it
    if [ "$STACK_WAS_STOPPED" = "1" ]; then
        warn "trap: stack was stopped by us, restarting now"
        if ! start_stack; then
            err "CRITICAL: stack did not come back up - manual intervention required"
            [ $rc -eq 0 ] && rc=3
            notify_unraid \
                "immich-backup: STACK RESTART FAILED" \
                "The Immich stack was stopped for a backup and did not come back up. Investigate now. Log: $LOG_FILE" \
                "alert"
        fi
    fi
    if [ $rc -ne 0 ]; then
        err "exited with rc=$rc  ·  log: $LOG_FILE"
        [ $rc -ne 3 ] && notify_unraid \
            "immich-backup: run failed (rc=$rc)" \
            "The backup run did not complete cleanly. Stack was restarted. Log: $LOG_FILE" \
            "warning"
    fi
    exit $rc
}

# =========================================================================
# MAIN
# =========================================================================
run_backup() {
    STAMP="$(date +%Y%m%d-%H%M)"
    DEST_DIR="$DEST_ROOT/$STAMP"
    DEST_TMP="$DEST_ROOT/.in-progress-$STAMP"
    # log to /tmp during preflight (dest dir may not exist yet); promoted below for real runs
    LOG_FILE="/tmp/${TOOL}-${MODE}-${STAMP}.log"
    : >"$LOG_FILE" 2>/dev/null || true

    banner "backup run  ·  stamp $STAMP"
    demo_report

    if ! preflight; then
        err "preflight failed - aborting before touching anything"
        return 1
    fi

    if [ "$MODE" != "dry" ]; then
        mkdir -p "$DEST_ROOT"
        local perm_log="$DEST_ROOT/${TOOL}.log"
        cat "$LOG_FILE" >>"$perm_log" 2>/dev/null && rm -f "$LOG_FILE"
        LOG_FILE="$perm_log"
        echo $$ >"$LOCKFILE"
        mkdir -p "$DEST_TMP"
    fi

    if ! stop_stack; then
        err "could not stop stack; trap will attempt restart"
        return 2
    fi

    local phase_rc=0
    backup_appdata || phase_rc=2
    backup_compose || phase_rc=2
    # photos last: largest, most likely to fail on space; appdata/compose already safe
    backup_photos  || phase_rc=2

    write_manifest || phase_rc=2

    if ! start_stack; then
        err "STACK RESTART FAILED"
        return 3
    fi

    if [ $phase_rc -eq 0 ] && [ "$MODE" != "dry" ]; then
        mv "$DEST_TMP" "$DEST_DIR" && ok "backup finalized at $DEST_DIR" || phase_rc=2
        DEST_TMP=""
    fi

    rotate

    if [ $phase_rc -eq 0 ] && [ "$MODE" != "dry" ]; then
        local size_h
        size_h=$(du -sh "$DEST_DIR" 2>/dev/null | awk '{print $1}')
        notify_unraid \
            "immich-backup: ${STAMP} complete (${size_h:-?})" \
            "Immich backup finished cleanly at ${DEST_DIR}. Stack is up. Log: $LOG_FILE" \
            "normal"
    fi

    banner_close
    return $phase_rc
}

main() {
    local raw_argc=$#
    parse_args "$@"
    case "$MODE" in
        help) usage; exit 0 ;;
    esac

    demo_collect

    # Handoff: bare User Scripts click (no TTY + no args) heading for a real
    # backup run is the dangerous case. Any flag — including read-only modes —
    # bypasses this. Env-var UNRAID_SCRIPTS_NO_HANDOFF=1 disables globally.
    if [ "$MODE" = "run" ] && { [ ! -t 0 ] || [ ! -t 1 ]; } && [ "$raw_argc" -eq 0 ]; then
        handoff_to_terminal
        exit 0
    fi

    # Interactive review-and-confirm screen for real backup runs on a TTY.
    if [ "$MODE" = "run" ] && [ "$CONFIRM" != "1" ]; then
        setup_tui
    fi

    case "$MODE" in
        list)
            list_backups
            exit 0
            ;;
        remind)
            remind
            exit $?
            ;;
        verify)
            verify_backup
            exit $?
            ;;
        restore)
            restore_backup
            exit $?
            ;;
        preflight)
            banner "preflight only  ·  no changes will be made"
            demo_report
            LOG_FILE="/tmp/${TOOL}-preflight.log"
            : >"$LOG_FILE"
            if preflight; then
                banner_close
                ok "preflight passed"
                exit 0
            else
                banner_close
                err "preflight failed"
                exit 1
            fi
            ;;
    esac

    # run / dry
    trap cleanup_trap EXIT INT TERM
    run_backup
    exit $?
}

main "$@"
