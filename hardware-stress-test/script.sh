#!/bin/bash
#
# hardware-stress-test — CPU + RAM stress test with crash forensics
#
# Part of: https://github.com/<you>/unraid-scripts
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
# every 15s it writes phase + elapsed + temperature + load to the FLASH DRIVE
# (sync'd immediately) and to syslog. If the machine locks up, the last
# heartbeat tells you exactly which phase it was in, how far in, and how hot
# it was — evidence that survives the power cycle.
#
# RUNS NATIVELY, NOT IN A CONTAINER. This is deliberate. If you are chasing an
# unexplained lockup, Docker is a suspect; stressing the CPU *through* a
# container confounds the result.
#
# ---------------------------------------------------------------------------
# DEPENDENCIES: none. Uses only openssl, sha512sum, dd, free, nproc — all of
# which ship with Unraid base. No Nerd Tools (deprecated), no package installs.
#
# WRITES: only to /dev/shm/stresstest (its own scratch, removed on exit) and
# one log file in /boot/logs/. Never touches your shares or your array.
#
# ---------------------------------------------------------------------------
# RECOMMENDED PROCEDURE
#
#   1. STOP THE ARRAY before running. The test needs only /dev/shm and /boot.
#      With the array stopped, nothing is in flight — so if the box does lock
#      up, the unclean shutdown is harmless. No parity invalidation, no
#      filesystem damage. There is no reason to risk your data for this.
#
#   2. Run it. ~2 hours by default.
#
#   3. After a lockup: reboot, then read /boot/logs/stress-test-*.log
#
# INSTALL: Settings -> User Scripts -> Add New Script -> paste -> Run in Background
# ---------------------------------------------------------------------------

##### CONFIG #####
CPU_MINUTES=45          # Phase 1: CPU only
RAM_MINUTES=30          # Phase 2: RAM write/verify
COMBO_MINUTES=45        # Phase 3: CPU + RAM together
RAM_TEST_GB=16          # RAM to exercise. Keep well under total.
TEMP_ABORT=92           # Abort if CPU reaches this (deg C).
HEARTBEAT_SEC=15
##################

LOGDIR="/boot/logs"
LOG="$LOGDIR/stress-test-$(date +%Y%m%d-%H%M%S).log"
SHM="/dev/shm/stresstest"
CORES=$(nproc)
PIDS=()

mkdir -p "$LOGDIR"

say() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $msg" | tee -a "$LOG"
    logger -t stress-test -p kern.notice "$msg"
    sync    # force to flash NOW — this is the whole point
}

cpu_temp() {
    if command -v sensors >/dev/null 2>&1; then
        sensors 2>/dev/null | grep -iE 'Package id 0|Tctl|Core 0' \
            | grep -oE '\+[0-9]+\.[0-9]+' | head -1 | tr -d '+' | cut -d. -f1
    fi
}

status_line() {
    local t; t=$(cpu_temp)
    local load; load=$(cut -d' ' -f1-3 /proc/loadavg)
    local mem; mem=$(free -m | awk '/^Mem:/{printf "%dM used / %dM free", $3, $4}')
    echo "temp=${t:-?}C load=$load mem=$mem"
}

cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    PIDS=()
    rm -rf "$SHM"
}
trap 'say "!!! INTERRUPTED !!!"; cleanup; exit 130' INT TERM

heartbeat() {
    local phase="$1" endtime="$2"
    while [ "$(date +%s)" -lt "$endtime" ]; do
        local remain=$(( (endtime - $(date +%s)) / 60 ))
        say "[$phase] alive  ${remain}m left  $(status_line)"
        local t; t=$(cpu_temp)
        if [ -n "$t" ] && [ "$t" -ge "$TEMP_ABORT" ] 2>/dev/null; then
            say "!!! CPU ${t}C >= ${TEMP_ABORT}C — ABORTING FOR SAFETY !!!"
            cleanup
            exit 1
        fi
        sleep "$HEARTBEAT_SEC"
    done
}

# AES-NI on half the cores, SHA512 on the other half — exercises both the
# crypto units and the integer/memory path, and generates real heat.
start_cpu_load() {
    local n=$1
    for i in $(seq 1 "$n"); do
        if [ $((i % 2)) -eq 0 ]; then
            ( while :; do openssl speed -evp aes-256-gcm >/dev/null 2>&1; done ) &
        else
            ( sha512sum /dev/zero >/dev/null 2>&1 ) &
        fi
        PIDS+=($!)
    done
}

# Write a known pattern into RAM (/dev/shm is tmpfs = RAM), then re-checksum it
# in a loop. A mismatch means a bit flipped. That is a hardware fault, full stop.
ram_verify_loop() {
    local endtime=$1
    mkdir -p "$SHM"
    say "  building ${RAM_TEST_GB}G test pattern in /dev/shm ..."
    dd if=/dev/urandom of="$SHM/seed" bs=1M count=256 2>/dev/null
    local ref; ref=$(sha512sum "$SHM/seed" | cut -d' ' -f1)
    for i in $(seq 1 $((RAM_TEST_GB * 4))); do
        cp "$SHM/seed" "$SHM/blk_$i" 2>/dev/null || { say "  !! cp failed at blk_$i (shm full?)"; break; }
    done
    local blocks; blocks=$(ls "$SHM"/blk_* 2>/dev/null | wc -l)
    say "  pattern built: $blocks blocks x 256M. Verifying in a loop..."

    local pass=0 fail=0
    while [ "$(date +%s)" -lt "$endtime" ]; do
        for f in "$SHM"/blk_*; do
            [ -f "$f" ] || continue
            local h; h=$(sha512sum "$f" | cut -d' ' -f1)
            if [ "$h" != "$ref" ]; then
                fail=$((fail+1))
                say "  *** RAM CORRUPTION DETECTED in $f ***"
                say "  *** expected $ref"
                say "  *** got      $h"
            else
                pass=$((pass+1))
            fi
            [ "$(date +%s)" -ge "$endtime" ] && break
        done
    done
    say "  RAM verify: $pass ok, $fail CORRUPT"
    [ "$fail" -gt 0 ] && say "  *** ${fail} MEMORY ERRORS — THIS IS A HARDWARE FAULT ***"
    rm -rf "$SHM"
}

run_phase() {
    local name="$1" mins="$2" cpu_workers="$3" do_ram="$4"
    local endtime=$(( $(date +%s) + mins * 60 ))

    say ""
    say "############################################################"
    say "### PHASE: $name  (${mins} min)"
    say "############################################################"

    [ "$cpu_workers" -gt 0 ] && { start_cpu_load "$cpu_workers"; say "  started $cpu_workers CPU workers"; }

    heartbeat "$name" "$endtime" &
    local hb=$!

    if [ "$do_ram" = "yes" ]; then
        ram_verify_loop "$endtime"
    else
        while [ "$(date +%s)" -lt "$endtime" ]; do sleep 10; done
    fi

    kill "$hb" 2>/dev/null
    cleanup
    say "### PHASE $name COMPLETE"
}

########################  MAIN  ########################
say "================================================================"
say "STRESS TEST STARTING"
say "  cores:  $CORES"
say "  ram:    $(free -g | awk '/^Mem:/{print $2}')G total"
say "  log:    $LOG   (flash — survives a lockup)"
say "  plan:   CPU ${CPU_MINUTES}m -> RAM ${RAM_MINUTES}m -> COMBO ${COMBO_MINUTES}m"
say "  start:  $(status_line)"
say "================================================================"
say ""
say "IF THE BOX LOCKS UP: after reboot, read $LOG"
say "The last heartbeat gives you the phase, the elapsed time, and the"
say "temperature at the moment of death."
say ""

run_phase "1-CPU-ONLY"   "$CPU_MINUTES"   "$CORES"          "no"
sleep 60
run_phase "2-RAM-VERIFY" "$RAM_MINUTES"   "0"               "yes"
sleep 60
run_phase "3-CPU+RAM"    "$COMBO_MINUTES" "$((CORES / 2))"  "yes"

say ""
say "================================================================"
say "ALL PHASES COMPLETE — the box survived the stress test"
say "  final: $(status_line)"
say ""
say "  A clean pass does NOT exonerate the hardware. Many lockups are"
say "  not load-triggered. If your machine dies while nearly idle, a"
say "  passing stress test tells you very little."
say ""
say "  The RAM verify count above is the meaningful line."
say "  Memtest86+ (Unraid boot menu) remains the definitive RAM test."
say "================================================================"
