#!/bin/bash
#
# hardware-stress-test v0.2.0 — CPU + RAM stress test with crash forensics
#
# Part of: https://github.com/herbiewalker/unraid-scripts
# License: MIT
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
#
# When an Unraid box hard-locks (kernel dead, BMC alive, power cycle required),
# the syslog dies with it — it lives in tmpfs. You reboot and the evidence is
# gone. Standard stress tools tell you "pass" or "fail", which is useless if
# the box freezes solid mid-run and takes the result with it.
#
# This script's real product is not the pass/fail. It is the HEARTBEAT TRAIL:
# every N seconds it writes phase + elapsed + temperature + load + hardware
# error counters to the FLASH DRIVE (sync'd immediately) and to syslog. If the
# machine locks up, the last heartbeat tells you exactly which phase it was in,
# how far in, and how hot it was — evidence that survives the power cycle.
#
# RUNS NATIVELY, NOT IN A CONTAINER. This is deliberate. If you are chasing an
# unexplained lockup, Docker is a suspect; stressing the CPU *through* a
# container confounds the result.
#
# ---------------------------------------------------------------------------
# WHAT IT WATCHES  (the part that actually finds hardware faults)
#
# The stress load is only there to provoke a fault. The evidence comes from
# the counters the hardware itself keeps:
#
#   EDAC (ECC RAM)  /sys/devices/system/edac/mc/mc*/{ce_count,ue_count}
#                   The authoritative memory-fault signal on ECC hardware.
#                   A rising CE count under load = a DIMM going bad. Any UE
#                   at all = uncorrectable, the machine is unwell.
#   MCE             Machine Check Exceptions in dmesg. CPU/cache/bus faults.
#   Throttling      /sys/devices/system/cpu/cpu*/thermal_throttle/*
#                   Separates "hot" from "so hot the CPU is protecting itself".
#   tmpfs checksums Our own RAM pattern verify. This is the fallback for
#                   non-ECC boxes, and the weakest of the four — it can only
#                   see a flip that lands in our pages while we hold them.
#
# ---------------------------------------------------------------------------
# DEPENDENCIES: none required.
#
# Temperature comes from /sys/class/hwmon directly, so lm-sensors is NOT
# needed. If stress-ng / memtester / sensors happen to be installed we will
# use them (they are better at their jobs), but nothing here requires them.
# No Nerd Tools (deprecated), no package installs.
#
# WRITES: only to /dev/shm/hardware-stress-test (its own scratch, removed on
# exit) and one log + one JSON summary in /boot/logs/. Never touches your
# shares or your array.
#
# ---------------------------------------------------------------------------
# RECOMMENDED PROCEDURE
#
#   1. STOP THE ARRAY before running. The test needs only /dev/shm and /boot.
#      With the array stopped, nothing is in flight — so if the box does lock
#      up, the unclean shutdown is harmless. No parity invalidation, no
#      filesystem damage. There is no reason to risk your data for this.
#
#   2. Run it. ~2 hours on the Standard profile.
#
#   3. After a lockup: reboot, then read /boot/logs/stress-test-*.log
#
# RUN IT FROM A TERMINAL (SSH, or the Unraid web terminal) to get the
# interactive setup screen. Run it from Settings -> User Scripts and it uses
# the defaults below / the flags you pass — there is no TTY there, so there
# is no setup screen. See --help.
# ---------------------------------------------------------------------------

set -u
set -o pipefail
# set -e is intentionally OFF (repo convention): a phase must be able to fail
# without killing the run, because a partial result is still evidence.

SCRIPT_VERSION="0.2.0"

# ============================================================
# Defaults (the Standard profile). Override via TUI or flags.
# ============================================================
PROFILE="Standard"
CPU_MINUTES=45          # Phase 1: CPU only
RAM_MINUTES=30          # Phase 2: RAM write/verify
COMBO_MINUTES=45        # Phase 3: CPU + RAM together
PHASE1_ON=1
PHASE2_ON=1
PHASE3_ON=1
RAM_TEST_GB="auto"      # "auto" = size it to the box; or an integer
TEMP_ABORT=92           # Abort if CPU reaches this (deg C)
HEARTBEAT_SEC=15
COOLDOWN_SEC=60         # Between phases
ENGINE="auto"           # auto | builtin | stress-ng
STOP_ON_ERROR=0
ASSUME_YES=0
USE_TUI="auto"          # auto | never
PREFLIGHT_ONLY=0
OVERRIDE_ARRAY=0

LOGDIR="/boot/logs"
SHM_ROOT="/dev/shm/hardware-stress-test"
LOCKFILE="/var/run/hardware-stress-test.lock"

# ============================================================
# Runtime state
# ============================================================
CORES=$(nproc 2>/dev/null || echo 1)
PIDS=()
LOG=""
JSON=""
SHM_DATA="$SHM_ROOT/data"
STATE="$SHM_ROOT/state"
RUN_START=0
ABORT_REASON=""
EXIT_CODE=0
HELD_LOCK=0

# Capability flags, filled in by detect_capabilities()
HAVE_SENSORS=0
HAVE_STRESS_NG=0
HAVE_MEMTESTER=0
HAVE_PGREP=0
HAVE_HWMON=0
HWMON_SRC=""
HAVE_EDAC=0
EDAC_CTRL=""
HAVE_THROTTLE=0
ARRAY_STATE="unknown"
IS_ROOT=0

# Baselines / totals for the summary
EDAC_CE_START=0
EDAC_UE_START=0
EDAC_CE_END=0
EDAC_UE_END=0
MCE_START=0
MCE_END=0
THROTTLE_START=0
THROTTLE_END=0
TEMP_MAX=0
RAM_PASS_TOTAL=0
RAM_FAIL_TOTAL=0
PHASES_RUN=""

# ============================================================
# Argument parsing
# ============================================================
usage() {
  cat <<'EOF'
hardware-stress-test — CPU + RAM stress test with crash-forensic logging

Usage: script.sh [options]

  Run from a terminal (SSH / Unraid web terminal) with no options to get an
  interactive setup screen. Run it under User Scripts (no TTY) and it uses
  the Standard profile unless you pass flags.

Profiles:
  --profile <name>      quick | standard | burn-in     (default: standard)
                          quick     ~16m   smoke test
                          standard  ~2h2m  the usual
                          burn-in   ~7h32m new/suspect hardware

Phase selection and timing:
  --phases <list>       Comma list of phases to run, e.g. 1,3  (default: 1,2,3)
  --cpu-min <n>         Phase 1 minutes
  --ram-min <n>         Phase 2 minutes
  --combo-min <n>       Phase 3 minutes
  --cooldown <n>        Seconds between phases (default: 60)

Tuning:
  --ram-gb <n|auto>     RAM to exercise (default: auto — sized to the box)
  --temp-abort <c>      Abort at this CPU temperature (default: 92)
  --heartbeat <n>       Heartbeat interval in seconds (default: 15)
  --engine <name>       auto | builtin | stress-ng   (default: auto)
  --stop-on-error       Stop immediately on the first RAM/ECC error

Behaviour:
  --preflight-only      Run the preflight checks, print them, exit
  --no-tui              Never show the setup screen, even on a terminal
  --yes, -y             Skip the confirmation prompt
  --override-array      Run even if the array is started (NOT recommended)
  --version             Print version and exit
  --help, -h            This text

Exit codes:
  0  all phases completed, no hardware errors detected
  1  usage / preflight failure (did not run)
  2  hardware error detected (ECC, MCE, or RAM checksum mismatch)
  3  aborted on temperature
  130 interrupted
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)   shift; apply_profile "${1:-}" || { printf 'Unknown profile: %s\n' "${1:-}" >&2; exit 1; } ;;
      --phases)    shift; set_phases "${1:-}" || exit 1 ;;
      --cpu-min)   shift; CPU_MINUTES="${1:-}";   PROFILE="Custom" ;;
      --ram-min)   shift; RAM_MINUTES="${1:-}";   PROFILE="Custom" ;;
      --combo-min) shift; COMBO_MINUTES="${1:-}"; PROFILE="Custom" ;;
      --cooldown)  shift; COOLDOWN_SEC="${1:-}" ;;
      --ram-gb)    shift; RAM_TEST_GB="${1:-}" ;;
      --temp-abort) shift; TEMP_ABORT="${1:-}" ;;
      --heartbeat) shift; HEARTBEAT_SEC="${1:-}" ;;
      --engine)    shift; ENGINE="${1:-}" ;;
      --stop-on-error) STOP_ON_ERROR=1 ;;
      --preflight-only) PREFLIGHT_ONLY=1 ;;
      --no-tui)    USE_TUI="never" ;;
      --yes|-y)    ASSUME_YES=1 ;;
      --override-array) OVERRIDE_ARRAY=1 ;;
      --version)   printf 'hardware-stress-test %s\n' "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h)   usage; exit 0 ;;
      *) printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 1 ;;
    esac
    shift
  done
  validate_args
}

apply_profile() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    quick)    PROFILE="Quick";    CPU_MINUTES=5;   RAM_MINUTES=5;  COMBO_MINUTES=5 ;;
    standard) PROFILE="Standard"; CPU_MINUTES=45;  RAM_MINUTES=30; COMBO_MINUTES=45 ;;
    burn-in|burnin) PROFILE="Burn-in"; CPU_MINUTES=120; RAM_MINUTES=90; COMBO_MINUTES=240 ;;
    custom)   PROFILE="Custom" ;;
    *) return 1 ;;
  esac
  return 0
}

set_phases() {
  local list="${1:-}"
  [ -n "$list" ] || return 1
  PHASE1_ON=0; PHASE2_ON=0; PHASE3_ON=0
  local p
  for p in ${list//,/ }; do
    case "$p" in
      1) PHASE1_ON=1 ;;
      2) PHASE2_ON=1 ;;
      3) PHASE3_ON=1 ;;
      *) printf 'Unknown phase: %s (valid: 1,2,3)\n' "$p" >&2; return 1 ;;
    esac
  done
  return 0
}

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

validate_args() {
  local n
  for n in CPU_MINUTES RAM_MINUTES COMBO_MINUTES COOLDOWN_SEC TEMP_ABORT HEARTBEAT_SEC; do
    is_uint "${!n}" || { printf '%s must be a non-negative integer (got: %s)\n' "$n" "${!n}" >&2; exit 1; }
  done
  [ "$RAM_TEST_GB" = "auto" ] || is_uint "$RAM_TEST_GB" || {
    printf -- '--ram-gb must be an integer or "auto" (got: %s)\n' "$RAM_TEST_GB" >&2; exit 1; }
  [ "$HEARTBEAT_SEC" -ge 1 ] || { printf -- '--heartbeat must be >= 1\n' >&2; exit 1; }
  [ "$TEMP_ABORT" -ge 40 ] || { printf -- '--temp-abort below 40C would abort instantly\n' >&2; exit 1; }
  case "$ENGINE" in auto|builtin|stress-ng) ;; *) printf -- '--engine must be auto|builtin|stress-ng\n' >&2; exit 1 ;; esac
}

# ============================================================
# Capability detection — everything here is optional
# ============================================================
detect_capabilities() {
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && IS_ROOT=1
  command -v sensors    >/dev/null 2>&1 && HAVE_SENSORS=1
  command -v stress-ng  >/dev/null 2>&1 && HAVE_STRESS_NG=1
  command -v memtester  >/dev/null 2>&1 && HAVE_MEMTESTER=1
  command -v pgrep      >/dev/null 2>&1 && HAVE_PGREP=1

  # Temperature straight from sysfs — no lm-sensors needed. Only trust hwmon
  # devices that are actually the CPU; a drive's temp*_input would otherwise
  # win the max and make the thermal guard meaningless.
  local h name
  for h in /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    name=$(cat "$h/name" 2>/dev/null) || continue
    case "$name" in
      coretemp|k10temp|zenpower|cpu_thermal|k8temp)
        HAVE_HWMON=1; HWMON_SRC="$name"; break ;;
    esac
  done

  local mc
  for mc in /sys/devices/system/edac/mc/mc*; do
    [ -r "$mc/ce_count" ] || continue
    HAVE_EDAC=1
    [ -r "$mc/mc_name" ] && EDAC_CTRL=$(cat "$mc/mc_name" 2>/dev/null)
    break
  done

  [ -r /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count ] && HAVE_THROTTLE=1

  detect_array_state
  resolve_engine
}

detect_array_state() {
  # Unraid exposes mdState in /proc/mdstat; mdcmd is the belt-and-braces path.
  if [ -r /proc/mdstat ] && grep -q 'mdState=' /proc/mdstat 2>/dev/null; then
    ARRAY_STATE=$(grep -m1 'mdState=' /proc/mdstat 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
  elif command -v mdcmd >/dev/null 2>&1; then
    ARRAY_STATE=$(mdcmd status 2>/dev/null | grep -m1 'mdState=' | cut -d= -f2 | tr -d '[:space:]')
  fi
  [ -n "$ARRAY_STATE" ] || ARRAY_STATE="unknown"
}

resolve_engine() {
  case "$ENGINE" in
    auto)      [ "$HAVE_STRESS_NG" = 1 ] && ENGINE_ACTIVE="stress-ng" || ENGINE_ACTIVE="builtin" ;;
    stress-ng) if [ "$HAVE_STRESS_NG" = 1 ]; then ENGINE_ACTIVE="stress-ng"
               else ENGINE_ACTIVE="builtin"; fi ;;
    builtin)   ENGINE_ACTIVE="builtin" ;;
  esac
}
ENGINE_ACTIVE="builtin"

# ============================================================
# Sizing
# ============================================================
ram_total_gb() { awk '/^MemTotal:/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0; }
shm_avail_gb() { df -k /dev/shm 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}' || echo 0; }

# Take 80% of what tmpfs will actually hand us, but never more than a third of
# physical RAM. Filling tmpfs to the brim doesn't test more memory, it just
# invites the OOM killer — and an OOM kill mid-run looks exactly like the
# lockup we're trying to diagnose.
autosize_ram_gb() {
  local by_shm by_ram pick
  by_shm=$(( $(shm_avail_gb) * 80 / 100 ))
  by_ram=$(( $(ram_total_gb) / 3 ))
  pick=$by_shm
  [ "$by_ram" -lt "$pick" ] && pick=$by_ram
  [ "$pick" -lt 1 ] && pick=1
  printf '%d' "$pick"
}

effective_ram_gb() {
  if [ "$RAM_TEST_GB" = "auto" ]; then autosize_ram_gb; else printf '%d' "$RAM_TEST_GB"; fi
}

est_runtime_min() {
  local t=0 n=0
  [ "$PHASE1_ON" = 1 ] && { t=$((t + CPU_MINUTES));   n=$((n+1)); }
  [ "$PHASE2_ON" = 1 ] && { t=$((t + RAM_MINUTES));   n=$((n+1)); }
  [ "$PHASE3_ON" = 1 ] && { t=$((t + COMBO_MINUTES)); n=$((n+1)); }
  [ "$n" -gt 1 ] && t=$(( t + (n - 1) * COOLDOWN_SEC / 60 ))
  printf '%d' "$t"
}

fmt_hm() {
  local m="${1:-0}"
  if [ "$m" -ge 60 ]; then printf '%dh %02dm' $((m / 60)) $((m % 60)); else printf '%dm' "$m"; fi
}

# ============================================================
# Sensors
# ============================================================
# Max across every CPU core, not core 0. A single hot core is exactly the
# fault you want to catch, and it will not show up in the package average.
cpu_temp() {
  local t="" v h name
  if [ "$HAVE_HWMON" = 1 ]; then
    for h in /sys/class/hwmon/hwmon*; do
      [ -r "$h/name" ] || continue
      name=$(cat "$h/name" 2>/dev/null) || continue
      case "$name" in
        coretemp|k10temp|zenpower|cpu_thermal|k8temp) ;;
        *) continue ;;
      esac
      for v in "$h"/temp*_input; do
        [ -r "$v" ] || continue
        local raw; raw=$(cat "$v" 2>/dev/null) || continue
        is_uint "$raw" || continue
        raw=$((raw / 1000))
        [ -z "$t" ] && t=$raw
        [ "$raw" -gt "$t" ] && t=$raw
      done
    done
  fi
  if [ -z "$t" ] && [ "$HAVE_SENSORS" = 1 ]; then
    t=$(sensors -u 2>/dev/null | awk '/temp[0-9]+_input:/{print $2}' | sort -rn | head -1 | cut -d. -f1)
  fi
  printf '%s' "$t"
}

edac_sum() {
  local kind="$1" total=0 f v
  for f in /sys/devices/system/edac/mc/mc*/"$kind"; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null) || continue
    is_uint "$v" || continue
    total=$((total + v))
  done
  printf '%d' "$total"
}

throttle_sum() {
  local total=0 f v
  for f in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null) || continue
    is_uint "$v" || continue
    total=$((total + v))
  done
  printf '%d' "$total"
}

mce_count() {
  local n
  n=$(dmesg 2>/dev/null | grep -ciE 'machine check|hardware error|\bmce\b|edac.*(corrected|uncorrected)')
  is_uint "$n" || n=0
  printf '%d' "$n"
}

load_avg() { cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "?"; }
mem_line() { free -m 2>/dev/null | awk '/^Mem:/{printf "%dM used / %dM free", $3, $4}'; }

status_line() {
  local t; t=$(cpu_temp)
  printf 'temp=%sC load=%s mem=%s' "${t:-?}" "$(load_avg)" "$(mem_line)"
}

# ============================================================
# Logging
# ============================================================
say() {
  local msg="$1"
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOG"
  logger -t stress-test -p kern.notice "$msg" 2>/dev/null
  # Force to flash NOW. This is the whole point: if the kernel dies one
  # instruction from here, this line still has to be on the drive.
  sync
}

# ============================================================
# Preflight
# ============================================================
PREFLIGHT_FATAL=0
PREFLIGHT_NOTES=()

preflight() {
  PREFLIGHT_FATAL=0
  PREFLIGHT_NOTES=()

  if [ "$IS_ROOT" != 1 ]; then
    PREFLIGHT_NOTES+=("FATAL|not root — /boot/logs and /dev/shm need root")
    PREFLIGHT_FATAL=1
  fi

  if [ "$HAVE_HWMON" = 1 ]; then
    PREFLIGHT_NOTES+=("OK|CPU temp via hwmon ($HWMON_SRC)")
  elif [ "$HAVE_SENSORS" = 1 ]; then
    PREFLIGHT_NOTES+=("WARN|no CPU hwmon — falling back to lm-sensors")
  else
    PREFLIGHT_NOTES+=("WARN|no temperature source — THERMAL ABORT DISABLED")
  fi

  if [ "$HAVE_EDAC" = 1 ]; then
    PREFLIGHT_NOTES+=("OK|ECC/EDAC present${EDAC_CTRL:+ ($EDAC_CTRL)}")
  else
    PREFLIGHT_NOTES+=("WARN|no EDAC — non-ECC RAM, or EDAC driver not loaded")
  fi

  [ "$HAVE_THROTTLE" = 1 ] \
    && PREFLIGHT_NOTES+=("OK|thermal throttle counters available") \
    || PREFLIGHT_NOTES+=("WARN|no throttle counters — cannot detect throttling")

  case "$ARRAY_STATE" in
    STOPPED) PREFLIGHT_NOTES+=("OK|array is STOPPED") ;;
    STARTED)
      if [ "$OVERRIDE_ARRAY" = 1 ]; then
        PREFLIGHT_NOTES+=("WARN|array is STARTED — overridden, a lockup risks your data")
      else
        PREFLIGHT_NOTES+=("FATAL|array is STARTED — stop it first (or --override-array)")
        PREFLIGHT_FATAL=1
      fi ;;
    *) PREFLIGHT_NOTES+=("WARN|array state unknown — is this Unraid?") ;;
  esac

  local want; want=$(effective_ram_gb)
  local avail; avail=$(shm_avail_gb)
  if [ "$want" -gt "$avail" ]; then
    PREFLIGHT_NOTES+=("FATAL|RAM test wants ${want}G, /dev/shm has ${avail}G")
    PREFLIGHT_FATAL=1
  else
    PREFLIGHT_NOTES+=("OK|RAM test ${want}G (of $(ram_total_gb)G, shm free ${avail}G)")
  fi

  if [ ! -d "$LOGDIR" ] && ! mkdir -p "$LOGDIR" 2>/dev/null; then
    PREFLIGHT_NOTES+=("FATAL|cannot create $LOGDIR")
    PREFLIGHT_FATAL=1
  fi

  PREFLIGHT_NOTES+=("OK|load engine: $ENGINE_ACTIVE")
  return 0
}

print_preflight() {
  local n kind text
  printf '\nPreflight:\n'
  for n in "${PREFLIGHT_NOTES[@]}"; do
    kind="${n%%|*}"; text="${n#*|}"
    case "$kind" in
      OK)    printf '  [ ok ] %s\n' "$text" ;;
      WARN)  printf '  [warn] %s\n' "$text" ;;
      FATAL) printf '  [FAIL] %s\n' "$text" ;;
    esac
  done
  printf '\n'
}

# ============================================================
# Locking
# ============================================================
acquire_lock() {
  if [ -e "$LOCKFILE" ]; then
    local old; old=$(cat "$LOCKFILE" 2>/dev/null)
    if is_uint "${old:-}" && kill -0 "$old" 2>/dev/null; then
      printf 'Another run is already in progress (pid %s). Refusing to start.\n' "$old" >&2
      printf 'Two stress tests sharing /dev/shm would corrupt each other'"'"'s results.\n' >&2
      return 1
    fi
    rm -f "$LOCKFILE" 2>/dev/null
  fi
  mkdir -p "$(dirname "$LOCKFILE")" 2>/dev/null
  printf '%s' "$$" > "$LOCKFILE" 2>/dev/null || return 0
  HELD_LOCK=1
  return 0
}

release_lock() { [ "$HELD_LOCK" = 1 ] && rm -f "$LOCKFILE" 2>/dev/null; return 0; }

# ============================================================
# Process control
# ============================================================
kill_tree() {
  local pid="$1" sig="$2" c
  if [ "$HAVE_PGREP" = 1 ]; then
    for c in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$c" "$sig"; done
  fi
  kill -"$sig" "$pid" 2>/dev/null
  return 0
}

# The workers are `( cmd ) &` subshells. Killing the subshell alone can leave
# the real load (openssl, sha512sum) reparented and still burning a core —
# bash won't run the subshell's trap until its foreground child exits, and
# openssl won't exit on its own. So walk the tree.
stop_load() {
  [ "${#PIDS[@]}" -eq 0 ] && return 0
  local p waited alive
  for p in "${PIDS[@]}"; do kill_tree "$p" TERM; done
  waited=0
  while [ "$waited" -lt 5 ]; do
    alive=0
    for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ "$alive" = 0 ] && break
    sleep 1; waited=$((waited + 1))
  done
  for p in "${PIDS[@]}"; do kill_tree "$p" KILL; done
  wait 2>/dev/null
  PIDS=()
  return 0
}

cleanup() {
  stop_load
  rm -rf "$SHM_ROOT" 2>/dev/null
  release_lock
  return 0
}

on_exit() { tui_show 2>/dev/null; cleanup; }
on_intr() {
  ABORT_REASON="interrupted"
  [ -n "$LOG" ] && say "!!! INTERRUPTED !!!"
  cleanup
  exit 130
}
trap on_exit EXIT
trap on_intr INT TERM

# ============================================================
# Load engines
# ============================================================
start_cpu_load() {
  local n="$1" i
  [ "$n" -gt 0 ] || return 0

  if [ "$ENGINE_ACTIVE" = "stress-ng" ]; then
    ( stress-ng --cpu "$n" --cpu-method all --timeout 0 --metrics-brief >/dev/null 2>&1 ) &
    PIDS+=($!)
    return 0
  fi

  # AES-NI on half the cores, SHA-512 on the other half — exercises the crypto
  # units and the integer/memory path, and generates real heat. `openssl enc`
  # rather than `openssl speed`: speed idles between block sizes, enc doesn't.
  for i in $(seq 1 "$n"); do
    if [ $((i % 2)) -eq 0 ]; then
      ( while :; do openssl enc -aes-256-ctr -nosalt -pass pass:stress \
          -in /dev/zero -out /dev/null 2>/dev/null; done ) &
    else
      ( while :; do sha512sum /dev/zero >/dev/null 2>&1; done ) &
    fi
    PIDS+=($!)
  done
  return 0
}

# Write a known pattern into RAM (/dev/shm is tmpfs = RAM), then re-checksum it
# in a loop. A mismatch means a bit flipped. That is a hardware fault, full stop.
#
# Runs as a BACKGROUND WORKER and reports through $STATE, because the monitor
# has to stay in the main process — see run_phase().
ram_verify_loop() {
  local endtime="$1" gb="$2"
  mkdir -p "$SHM_DATA" || { printf 'ERR|cannot create %s\n' "$SHM_DATA" > "$STATE/ram-status"; return 1; }

  printf 'building %sG pattern\n' "$gb" > "$STATE/ram-status"
  dd if=/dev/urandom of="$SHM_DATA/seed" bs=1M count=256 2>/dev/null || {
    printf 'ERR|seed failed\n' > "$STATE/ram-status"; return 1; }
  local ref; ref=$(sha512sum "$SHM_DATA/seed" | cut -d' ' -f1)

  local i blocks=0
  for i in $(seq 1 $((gb * 4))); do
    cp "$SHM_DATA/seed" "$SHM_DATA/blk_$i" 2>/dev/null || break
    blocks=$((blocks + 1))
  done
  printf 'verifying %d blocks x 256M\n' "$blocks" > "$STATE/ram-status"
  printf '%d' "$blocks" > "$STATE/ram-blocks"

  local pass=0 fail=0 f h
  while [ "$(date +%s)" -lt "$endtime" ]; do
    for f in "$SHM_DATA"/blk_*; do
      [ -f "$f" ] || continue
      h=$(sha512sum "$f" 2>/dev/null | cut -d' ' -f1)
      if [ "$h" != "$ref" ]; then
        fail=$((fail + 1))
        {
          printf '*** RAM CORRUPTION in %s\n' "$f"
          printf '    expected %s\n' "$ref"
          printf '    got      %s\n' "$h"
        } >> "$STATE/ram-errors"
      else
        pass=$((pass + 1))
      fi
      printf '%d' "$pass" > "$STATE/ram-pass"
      printf '%d' "$fail" > "$STATE/ram-fail"
      [ "$(date +%s)" -ge "$endtime" ] && break
    done
  done
  printf 'done\n' > "$STATE/ram-status"
  return 0
}

start_ram_load() {
  local endtime="$1" gb; gb=$(effective_ram_gb)
  : > "$STATE/ram-pass"; : > "$STATE/ram-fail"; : > "$STATE/ram-status"
  ram_verify_loop "$endtime" "$gb" &
  PIDS+=($!)
  return 0
}

read_state_int() {
  local f="$STATE/$1" v
  [ -r "$f" ] || { printf '0'; return 0; }
  v=$(cat "$f" 2>/dev/null)
  is_uint "${v:-}" && printf '%d' "$v" || printf '0'
}

# ============================================================
# Monitor — runs in the MAIN process
#
# This is the fix for the v0.1 bug where the thermal abort did nothing: the
# heartbeat used to run as `heartbeat ... &`, so its `exit 1` on an over-temp
# only killed the background subshell. The main script sailed on, finished the
# phase, and started the next one — re-applying full load to a box that had
# just hit its thermal limit, while the log said "ABORTING FOR SAFETY".
#
# The load is what belongs in the background. The monitor is control flow, so
# it stays here, and `return 1` genuinely stops the run.
# ============================================================
# 0 = phase completed, 1 = thermal abort, 2 = hardware error (stop-on-error)
monitor_phase() {
  local phase="$1" endtime="$2"
  local now t remain slice ce ue

  while :; do
    now=$(date +%s)
    [ "$now" -ge "$endtime" ] && return 0

    t=$(cpu_temp)
    [ -n "$t" ] && is_uint "$t" && [ "$t" -gt "$TEMP_MAX" ] && TEMP_MAX=$t

    remain=$(( (endtime - now) / 60 ))
    local extra=""
    if [ "$HAVE_EDAC" = 1 ]; then
      ce=$(edac_sum ce_count); ue=$(edac_sum ue_count)
      extra=" ecc_ce=$((ce - EDAC_CE_START)) ecc_ue=$((ue - EDAC_UE_START))"
    fi
    local rs=""
    [ -r "$STATE/ram-status" ] && rs=$(head -1 "$STATE/ram-status" 2>/dev/null)
    [ -n "$rs" ] && extra="$extra ram=[$rs]"

    say "[$phase] alive  ${remain}m left  $(status_line)${extra}"

    if [ -n "$t" ] && is_uint "$t" && [ "$t" -ge "$TEMP_ABORT" ]; then
      say "!!! CPU ${t}C >= ${TEMP_ABORT}C — ABORTING !!!"
      ABORT_REASON="thermal: ${t}C >= ${TEMP_ABORT}C"
      return 1
    fi

    if [ "$HAVE_EDAC" = 1 ] && [ "$((ue - EDAC_UE_START))" -gt 0 ]; then
      say "!!! UNCORRECTABLE ECC ERROR — this is a hardware fault !!!"
      ABORT_REASON="ecc: uncorrectable error"
      return 2
    fi

    if [ "$STOP_ON_ERROR" = 1 ] && [ "$(read_state_int ram-fail)" -gt 0 ]; then
      say "!!! RAM checksum mismatch — stopping (--stop-on-error) !!!"
      ABORT_REASON="ram: checksum mismatch"
      return 2
    fi

    # Sleep in 1s slices so the abort stays responsive: a trap or a long
    # `sleep $HEARTBEAT_SEC` would leave the box cooking for up to a full
    # interval after we already decided to stop.
    slice=$(( now + HEARTBEAT_SEC ))
    while [ "$(date +%s)" -lt "$slice" ]; do
      [ "$(date +%s)" -ge "$endtime" ] && return 0
      sleep 1
    done
  done
}

# ============================================================
# Phases
# ============================================================
run_phase() {
  local name="$1" mins="$2" cpu_workers="$3" do_ram="$4"
  local endtime=$(( $(date +%s) + mins * 60 ))
  local rc=0

  say ""
  say "############################################################"
  say "### PHASE: $name  (${mins} min)"
  say "############################################################"

  if [ "$cpu_workers" -gt 0 ]; then
    start_cpu_load "$cpu_workers"
    say "  started $cpu_workers CPU workers ($ENGINE_ACTIVE)"
  fi
  if [ "$do_ram" = "yes" ]; then
    start_ram_load "$endtime"
    say "  started RAM verifier ($(effective_ram_gb)G)"
  fi

  monitor_phase "$name" "$endtime"; rc=$?

  stop_load

  if [ "$do_ram" = "yes" ]; then
    local p f
    p=$(read_state_int ram-pass); f=$(read_state_int ram-fail)
    RAM_PASS_TOTAL=$((RAM_PASS_TOTAL + p))
    RAM_FAIL_TOTAL=$((RAM_FAIL_TOTAL + f))
    say "  RAM verify: $p ok, $f CORRUPT"
    if [ "$f" -gt 0 ]; then
      say "  *** ${f} MEMORY ERRORS — THIS IS A HARDWARE FAULT ***"
      [ -r "$STATE/ram-errors" ] && while IFS= read -r line; do say "  $line"; done < "$STATE/ram-errors"
    fi
    rm -rf "$SHM_DATA" 2>/dev/null
  fi

  [ "$rc" = 0 ] && say "### PHASE $name COMPLETE" || say "### PHASE $name ABORTED"
  PHASES_RUN="${PHASES_RUN}${PHASES_RUN:+,}$name"
  return $rc
}

cooldown() {
  [ "$COOLDOWN_SEC" -gt 0 ] || return 0
  say "  cooling down ${COOLDOWN_SEC}s"
  sleep "$COOLDOWN_SEC"
}

# ============================================================
# TUI — ANSI, no dependencies
#
# Padding is computed from a plain-ASCII "stencil" string rather than the
# coloured/unicode one, because ${#s} counts bytes in the C locale and would
# mis-measure both escape codes and multi-byte glyphs. Every stencil must be
# the same VISUAL width as the string it stands in for.
# ============================================================
W=67
C_RESET=$'\033[0m'; C_DIM=$'\033[2m';  C_BOLD=$'\033[1m'
C_RED=$'\033[31m';  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
C_CYA=$'\033[36m';  C_INV=$'\033[7m'

tui_hide()  { printf '\033[?25l'; }
tui_show()  { printf '\033[?25h'; }
tui_clear() { printf '\033[2J\033[H'; }
tui_home()  { printf '\033[H'; }

row() { local pad=$(( W - ${#1} )); [ "$pad" -lt 0 ] && pad=0; printf '│%s%*s│\n' "$1" "$pad" ""; }
rowc() {
  local stencil="$1" colored="$2"
  local pad=$(( W - ${#stencil} )); [ "$pad" -lt 0 ] && pad=0
  printf '│%s%*s│\n' "$colored" "$pad" ""
}
rule()  { printf '├'; local i=0; while [ $i -lt $W ]; do printf '─'; i=$((i+1)); done; printf '┤\n'; }
rule_t() { printf '┌'; local i=0; while [ $i -lt $W ]; do printf '─'; i=$((i+1)); done; printf '┐\n'; }
rule_b() { printf '└'; local i=0; while [ $i -lt $W ]; do printf '─'; i=$((i+1)); done; printf '┘\n'; }

TUI_FIELDS=(profile p1 p2 p3 ram temp hb engine)
TUI_CUR=0

tui_key() {
  local k rest
  IFS= read -rsn1 k 2>/dev/null || { printf 'quit'; return; }
  case "$k" in
    $'\033')
      read -rsn2 -t 0.05 rest 2>/dev/null
      case "${rest:-}" in
        '[A') printf 'up' ;;   '[B') printf 'down' ;;
        '[C') printf 'right' ;; '[D') printf 'left' ;;
        *)    printf 'esc' ;;
      esac ;;
    '')  printf 'enter' ;;
    ' ') printf 'space' ;;
    *)   printf '%s' "$k" ;;
  esac
}

clampi() { local v=$1 lo=$2 hi=$3; [ "$v" -lt "$lo" ] && v=$lo; [ "$v" -gt "$hi" ] && v=$hi; printf '%d' "$v"; }
# Clip a note to N chars so a long runtime value can never push a row past the
# box border. Notes are plain ASCII (no escapes), so byte length == visual width.
clip() { local s="$1" n="$2"; [ "${#s}" -gt "$n" ] && printf '%s' "${s:0:n}" || printf '%s' "$s"; }

tui_cycle_profile() {
  local dir=$1
  case "$PROFILE" in
    Quick)    [ "$dir" = 1 ] && apply_profile standard || apply_profile burn-in ;;
    Standard) [ "$dir" = 1 ] && apply_profile burn-in  || apply_profile quick ;;
    Burn-in)  [ "$dir" = 1 ] && apply_profile quick    || apply_profile standard ;;
    *)        apply_profile standard ;;
  esac
}

tui_cycle_engine() {
  case "$ENGINE" in
    auto)      ENGINE="builtin" ;;
    builtin)   [ "$HAVE_STRESS_NG" = 1 ] && ENGINE="stress-ng" || ENGINE="auto" ;;
    stress-ng) ENGINE="auto" ;;
  esac
  resolve_engine
}

tui_adjust() {
  local field="$1" dir="$2"
  case "$field" in
    profile) tui_cycle_profile "$dir"; return ;;
    p1)  CPU_MINUTES=$(clampi $((CPU_MINUTES + dir * 5)) 0 720) ;;
    p2)  RAM_MINUTES=$(clampi $((RAM_MINUTES + dir * 5)) 0 720) ;;
    p3)  COMBO_MINUTES=$(clampi $((COMBO_MINUTES + dir * 5)) 0 720) ;;
    ram)
      if [ "$RAM_TEST_GB" = "auto" ]; then
        [ "$dir" = 1 ] && RAM_TEST_GB=$(clampi $(( $(autosize_ram_gb) + 1 )) 1 4096) || RAM_TEST_GB=$(clampi $(( $(autosize_ram_gb) - 1 )) 1 4096)
      else
        RAM_TEST_GB=$((RAM_TEST_GB + dir))
        [ "$RAM_TEST_GB" -lt 1 ] && RAM_TEST_GB="auto"
      fi
      return ;;
    temp)   TEMP_ABORT=$(clampi $((TEMP_ABORT + dir)) 40 110); return ;;
    hb)     HEARTBEAT_SEC=$(clampi $((HEARTBEAT_SEC + dir * 5)) 5 300); return ;;
    engine) tui_cycle_engine; return ;;
  esac
  # Touching any phase duration means you're no longer on a named profile.
  PROFILE="Custom"
}

tui_toggle() {
  case "$1" in
    p1) PHASE1_ON=$((1 - PHASE1_ON)); PROFILE="Custom" ;;
    p2) PHASE2_ON=$((1 - PHASE2_ON)); PROFILE="Custom" ;;
    p3) PHASE3_ON=$((1 - PHASE3_ON)); PROFILE="Custom" ;;
  esac
}

sel() { [ "${TUI_FIELDS[$TUI_CUR]}" = "$1" ] && printf '%s' "$C_INV" || printf ''; }
chk() { [ "$1" = 1 ] && printf 'x' || printf ' '; }

tui_render() {
  tui_home
  local ram_disp ram_note eng_note
  if [ "$RAM_TEST_GB" = "auto" ]; then ram_disp="auto"; else ram_disp="${RAM_TEST_GB}"; fi
  ram_note="$(effective_ram_gb) G   ($(ram_total_gb) G total, shm free $(shm_avail_gb) G)"
  case "$ENGINE" in
    auto) [ "$HAVE_STRESS_NG" = 1 ] && eng_note="-> stress-ng detected, will use" || eng_note="-> built-ins (no stress-ng)" ;;
    builtin) eng_note="-> openssl + sha512sum" ;;
    stress-ng) [ "$HAVE_STRESS_NG" = 1 ] && eng_note="-> stress-ng" || eng_note="-> NOT FOUND, using built-ins" ;;
  esac
  # Clip to each field's budget: W minus the fixed prefix that precedes it.
  ram_note=$(clip "$ram_note" 37)
  eng_note=$(clip "$eng_note" 34)

  rule_t
  row ""
  rowc "  PROFILE    < $(printf '%-8s' "$PROFILE") >    Quick . Standard . Burn-in . Custom" \
       "  ${C_BOLD}PROFILE${C_RESET}    $(sel profile)< $(printf '%-8s' "$PROFILE") >${C_RESET}    ${C_DIM}Quick . Standard . Burn-in . Custom${C_RESET}"
  row ""
  rowc "  PHASES" "  ${C_BOLD}PHASES${C_RESET}"
  rowc "    [$(chk $PHASE1_ON)]  1  CPU only               $(printf '%3d' $CPU_MINUTES) min" \
       "    $(sel p1)[$(chk $PHASE1_ON)]  1  CPU only               $(printf '%3d' $CPU_MINUTES) min${C_RESET}"
  rowc "    [$(chk $PHASE2_ON)]  2  RAM verify             $(printf '%3d' $RAM_MINUTES) min" \
       "    $(sel p2)[$(chk $PHASE2_ON)]  2  RAM verify             $(printf '%3d' $RAM_MINUTES) min${C_RESET}"
  rowc "    [$(chk $PHASE3_ON)]  3  CPU + RAM              $(printf '%3d' $COMBO_MINUTES) min" \
       "    $(sel p3)[$(chk $PHASE3_ON)]  3  CPU + RAM              $(printf '%3d' $COMBO_MINUTES) min${C_RESET}"
  row ""
  rowc "  RAM test size   < $(printf '%4s' "$ram_disp") >    $ram_note" \
       "  RAM test size   $(sel ram)< $(printf '%4s' "$ram_disp") >${C_RESET}    ${C_DIM}${ram_note}${C_RESET}"
  rowc "  Abort at        < $(printf '%4d' $TEMP_ABORT) > C" \
       "  Abort at        $(sel temp)< $(printf '%4d' $TEMP_ABORT) >${C_RESET} C"
  rowc "  Heartbeat       < $(printf '%4d' $HEARTBEAT_SEC) > s" \
       "  Heartbeat       $(sel hb)< $(printf '%4d' $HEARTBEAT_SEC) >${C_RESET} s"
  rowc "  Load engine     < $(printf '%-9s' "$ENGINE") >  $eng_note" \
       "  Load engine     $(sel engine)< $(printf '%-9s' "$ENGINE") >${C_RESET}  ${C_DIM}${eng_note}${C_RESET}"
  row ""
  rule
  rowc " PREFLIGHT" " ${C_BOLD}PREFLIGHT${C_RESET}"

  preflight
  local n kind text col mark
  for n in "${PREFLIGHT_NOTES[@]}"; do
    kind="${n%%|*}"; text="${n#*|}"
    case "$kind" in
      OK)    col="$C_GRN"; mark="v" ;;
      WARN)  col="$C_YEL"; mark="!" ;;
      FATAL) col="$C_RED"; mark="x" ;;
    esac
    rowc "  $mark $text" "  ${col}${mark}${C_RESET} $text"
  done
  rule
  local est; est=$(fmt_hm "$(est_runtime_min)")
  rowc "  Est. runtime  $(printf '%-10s' "$est")  up/dn move  l/r change  ENTER start" \
       "  Est. runtime  ${C_BOLD}$(printf '%-10s' "$est")${C_RESET}  ${C_DIM}up/dn move  l/r change  ENTER start${C_RESET}"
  rule_b
  printf '%s  space toggle phase - a override array - q quit%s\033[K\n' "$C_DIM" "$C_RESET"
}

tui_run() {
  local k f
  tui_hide; tui_clear
  while :; do
    tui_render
    k=$(tui_key)
    f="${TUI_FIELDS[$TUI_CUR]}"
    case "$k" in
      up)    TUI_CUR=$(( (TUI_CUR - 1 + ${#TUI_FIELDS[@]}) % ${#TUI_FIELDS[@]} )) ;;
      down)  TUI_CUR=$(( (TUI_CUR + 1) % ${#TUI_FIELDS[@]} )) ;;
      left)  tui_adjust "$f" -1 ;;
      right) tui_adjust "$f" 1 ;;
      space) tui_toggle "$f" ;;
      a|A)   OVERRIDE_ARRAY=$((1 - OVERRIDE_ARRAY)) ;;
      q|Q|esc|quit) tui_show; tui_clear; printf 'Cancelled.\n'; exit 0 ;;
      enter)
        preflight
        if [ "$PREFLIGHT_FATAL" = 1 ]; then
          printf '%s  Cannot start: fix the red items above.%s\033[K\n' "$C_RED" "$C_RESET"
          sleep 2
          continue
        fi
        if [ "$((PHASE1_ON + PHASE2_ON + PHASE3_ON))" -eq 0 ]; then
          printf '%s  Cannot start: no phases selected.%s\033[K\n' "$C_RED" "$C_RESET"
          sleep 2
          continue
        fi
        tui_show; tui_clear
        return 0 ;;
    esac
  done
}

# ============================================================
# Summary
# ============================================================
write_summary() {
  local status="$1" elapsed=$(( $(date +%s) - RUN_START ))
  EDAC_CE_END=$(edac_sum ce_count)
  EDAC_UE_END=$(edac_sum ue_count)
  MCE_END=$(mce_count)
  THROTTLE_END=$(throttle_sum)

  local ce=$((EDAC_CE_END - EDAC_CE_START))
  local ue=$((EDAC_UE_END - EDAC_UE_START))
  local mce=$((MCE_END - MCE_START))
  local thr=$((THROTTLE_END - THROTTLE_START))

  say ""
  say "================================================================"
  say "RESULT: $status"
  say "  elapsed:        $(fmt_hm $((elapsed / 60)))"
  say "  phases run:     ${PHASES_RUN:-none}"
  say "  peak CPU temp:  ${TEMP_MAX}C"
  say "  ECC corrected:  $ce      (new during this run)"
  say "  ECC uncorrect.: $ue      (new during this run)"
  say "  MCE entries:    $mce      (new during this run)"
  say "  throttle events:$thr      (new during this run)"
  say "  RAM checksums:  $RAM_PASS_TOTAL ok, $RAM_FAIL_TOTAL CORRUPT"
  [ -n "$ABORT_REASON" ] && say "  abort reason:   $ABORT_REASON"
  say "================================================================"

  printf '{\n' > "$JSON"
  printf '  "version": "%s",\n'        "$SCRIPT_VERSION" >> "$JSON"
  printf '  "host": "%s",\n'           "$(hostname 2>/dev/null)" >> "$JSON"
  printf '  "status": "%s",\n'         "$status" >> "$JSON"
  printf '  "profile": "%s",\n'        "$PROFILE" >> "$JSON"
  printf '  "engine": "%s",\n'         "$ENGINE_ACTIVE" >> "$JSON"
  printf '  "phases_run": "%s",\n'     "$PHASES_RUN" >> "$JSON"
  printf '  "elapsed_sec": %d,\n'      "$elapsed" >> "$JSON"
  printf '  "cores": %d,\n'            "$CORES" >> "$JSON"
  printf '  "ram_total_gb": %d,\n'     "$(ram_total_gb)" >> "$JSON"
  printf '  "ram_tested_gb": %d,\n'    "$(effective_ram_gb)" >> "$JSON"
  printf '  "peak_temp_c": %d,\n'      "$TEMP_MAX" >> "$JSON"
  printf '  "temp_abort_c": %d,\n'     "$TEMP_ABORT" >> "$JSON"
  printf '  "have_ecc": %s,\n'         "$([ "$HAVE_EDAC" = 1 ] && echo true || echo false)" >> "$JSON"
  printf '  "ecc_corrected": %d,\n'    "$ce" >> "$JSON"
  printf '  "ecc_uncorrectable": %d,\n' "$ue" >> "$JSON"
  printf '  "mce_new": %d,\n'          "$mce" >> "$JSON"
  printf '  "throttle_events": %d,\n'  "$thr" >> "$JSON"
  printf '  "ram_checksums_ok": %d,\n' "$RAM_PASS_TOTAL" >> "$JSON"
  printf '  "ram_checksums_bad": %d,\n' "$RAM_FAIL_TOTAL" >> "$JSON"
  printf '  "abort_reason": "%s",\n'   "$ABORT_REASON" >> "$JSON"
  printf '  "log": "%s"\n'             "$LOG" >> "$JSON"
  printf '}\n' >> "$JSON"
  sync

  # A hardware error outranks a clean phase run: you can complete every phase
  # and still have a bad DIMM.
  if [ "$ue" -gt 0 ] || [ "$RAM_FAIL_TOTAL" -gt 0 ] || [ "$mce" -gt 0 ]; then
    EXIT_CODE=2
  fi
  return 0
}

interpret() {
  local ce=$((EDAC_CE_END - EDAC_CE_START))
  local ue=$((EDAC_UE_END - EDAC_UE_START))
  local mce=$((MCE_END - MCE_START))
  local thr=$((THROTTLE_END - THROTTLE_START))

  say ""
  if [ "$ue" -gt 0 ] || [ "$RAM_FAIL_TOTAL" -gt 0 ]; then
    say "  VERDICT: HARDWARE FAULT. Memory errors are not a software problem."
    say "  Run Memtest86+ from the Unraid boot menu, then start pulling DIMMs."
  elif [ "$mce" -gt 0 ]; then
    say "  VERDICT: MACHINE CHECK EXCEPTIONS logged. Read: dmesg | grep -i mce"
  elif [ "$ce" -gt 0 ]; then
    say "  VERDICT: ECC corrected $ce error(s). The RAM caught them, so nothing"
    say "  broke — but a DIMM that throws correctables under load is degrading."
  elif [ -n "$ABORT_REASON" ]; then
    say "  VERDICT: run did not complete ($ABORT_REASON)."
  else
    say "  VERDICT: passed. Read this narrowly."
    say ""
    say "  A clean pass does NOT exonerate the hardware. Many lockups are not"
    say "  load-triggered. If your machine dies while nearly idle, a passing"
    say "  stress test tells you very little. It rules out gross thermal and"
    say "  load-dependent faults, and nothing more."
    if [ "$HAVE_EDAC" != 1 ]; then
      say ""
      say "  No EDAC on this box, so there were no ECC counters to check — the"
      say "  checksum loop was the only memory evidence, and it only sees a"
      say "  flip that lands in our own pages. Memtest86+ is far more thorough."
    fi
  fi
  [ "$thr" -gt 0 ] && {
    say ""
    say "  NOTE: $thr thermal-throttle event(s). The CPU was hot enough to slow"
    say "  itself down. Check your cooling before trusting any timing result."
  }
  say "  Memtest86+ (Unraid boot menu) remains the definitive RAM test."
  return 0
}

# ============================================================
# MAIN
# ============================================================
main() {
  parse_args "$@"
  detect_capabilities

  if [ "$PREFLIGHT_ONLY" = 1 ]; then
    preflight
    printf 'hardware-stress-test %s — preflight only\n' "$SCRIPT_VERSION"
    printf '  host %s · %s cores · %sG RAM · engine %s\n' \
      "$(hostname 2>/dev/null)" "$CORES" "$(ram_total_gb)" "$ENGINE_ACTIVE"
    print_preflight
    exit $([ "$PREFLIGHT_FATAL" = 1 ] && echo 1 || echo 0)
  fi

  # No TTY (User Scripts runs us with stdout piped to a browser) means no
  # setup screen — an interactive prompt there would hang the job forever.
  if [ "$USE_TUI" = "auto" ] && [ -t 0 ] && [ -t 1 ]; then
    tui_run
  fi

  preflight
  if [ "$PREFLIGHT_FATAL" = 1 ]; then
    printf 'hardware-stress-test %s — preflight FAILED, not starting.\n' "$SCRIPT_VERSION" >&2
    print_preflight >&2
    exit 1
  fi
  if [ "$((PHASE1_ON + PHASE2_ON + PHASE3_ON))" -eq 0 ]; then
    printf 'No phases selected — nothing to do.\n' >&2
    exit 1
  fi

  acquire_lock || exit 1

  RUN_START=$(date +%s)
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$LOGDIR" 2>/dev/null
  LOG="$LOGDIR/stress-test-$stamp.log"
  JSON="$LOGDIR/stress-test-$stamp.json"
  mkdir -p "$STATE" 2>/dev/null

  EDAC_CE_START=$(edac_sum ce_count)
  EDAC_UE_START=$(edac_sum ue_count)
  MCE_START=$(mce_count)
  THROTTLE_START=$(throttle_sum)

  say "================================================================"
  say "STRESS TEST STARTING — v$SCRIPT_VERSION"
  say "  host:    $(hostname 2>/dev/null)"
  say "  profile: $PROFILE"
  say "  cores:   $CORES"
  say "  ram:     $(ram_total_gb)G total, testing $(effective_ram_gb)G"
  say "  engine:  $ENGINE_ACTIVE"
  say "  array:   $ARRAY_STATE"
  say "  ecc:     $([ "$HAVE_EDAC" = 1 ] && echo "yes${EDAC_CTRL:+ ($EDAC_CTRL)}" || echo "no EDAC")"
  say "  temp:    $([ "$HAVE_HWMON" = 1 ] && echo "hwmon/$HWMON_SRC" || echo "NONE — thermal abort disabled")"
  say "  log:     $LOG   (flash — survives a lockup)"
  say "  est:     $(fmt_hm "$(est_runtime_min)")"
  say "  start:   $(status_line)"
  say "================================================================"
  say ""
  say "IF THE BOX LOCKS UP: after reboot, read $LOG"
  say "The last heartbeat gives you the phase, the elapsed time, the"
  say "temperature, and the ECC counters at the moment of death."
  say ""

  local rc=0 first=1
  if [ "$PHASE1_ON" = 1 ] && [ "$CPU_MINUTES" -gt 0 ]; then
    first=0
    run_phase "1-CPU-ONLY" "$CPU_MINUTES" "$CORES" "no" || rc=$?
  fi
  if [ "$rc" = 0 ] && [ "$PHASE2_ON" = 1 ] && [ "$RAM_MINUTES" -gt 0 ]; then
    [ "$first" = 0 ] && cooldown; first=0
    run_phase "2-RAM-VERIFY" "$RAM_MINUTES" "0" "yes" || rc=$?
  fi
  if [ "$rc" = 0 ] && [ "$PHASE3_ON" = 1 ] && [ "$COMBO_MINUTES" -gt 0 ]; then
    [ "$first" = 0 ] && cooldown; first=0
    run_phase "3-CPU+RAM" "$COMBO_MINUTES" "$((CORES / 2))" "yes" || rc=$?
  fi

  case "$rc" in
    0) write_summary "COMPLETED" ;;
    1) write_summary "ABORTED-THERMAL"; EXIT_CODE=3 ;;
    2) write_summary "ABORTED-HARDWARE-ERROR"; EXIT_CODE=2 ;;
  esac
  interpret

  say ""
  say "  log:     $LOG"
  say "  summary: $JSON"
  exit "$EXIT_CODE"
}

main "$@"
