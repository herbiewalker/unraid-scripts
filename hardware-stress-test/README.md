# hardware-stress-test

CPU + RAM stress test for Unraid, built around **crash forensics** rather than a pass/fail
score.

## The problem it solves

When an Unraid box hard-locks — kernel dead, BMC still responding, power cycle required — the
syslog dies with it. Unraid's `/var/log` is **tmpfs**: it lives in RAM. You reboot, and the
evidence that would have explained the crash is gone.

Standard stress tools are built for a machine that survives the test. They print a result at
the end. If your box freezes solid at minute 37, you get nothing — not even the knowledge that
it froze at minute 37.

**So the real product of this script is not the pass/fail. It is the heartbeat trail.**

Every 15 seconds it writes phase, elapsed time, CPU temperature, load, and memory to:

- **`/boot/logs/stress-test-<timestamp>.log`** — on the flash drive, `sync`'d immediately, so
  it **survives a hard lockup**
- **syslog** — which means it also goes to your remote syslog server, if you have one

If the machine dies, you reboot and read the last line. It tells you which phase it was in, how
far in, and how hot it was. That is more than most people get out of an unexplained lockup.

## Why it runs natively, not in Docker

Deliberate. If you're chasing an unexplained lockup, **Docker is a suspect** — Unraid's own
release notes point at Docker custom-network problems as a first-line cause of "unexplained
crashes." Stressing the CPU *through* a container means a crash tells you nothing about
whether it was the CPU or the container runtime.

This runs on bare Unraid. One variable.

## What it actually tests

| Phase | Duration | What it does |
|---|---|---|
| **1 — CPU only** | 45 min | AES-NI (`openssl speed -evp aes-256-gcm`) on half the cores, SHA-512 on the other half. Exercises the crypto units, the integer path, and generates real heat. |
| **2 — RAM verify** | 30 min | Writes a known 16 GB pattern into `/dev/shm` (tmpfs = RAM), then re-checksums it in a loop. **A mismatch means a bit flipped in memory.** That is a hardware fault, and it is logged loudly. |
| **3 — CPU + RAM** | 45 min | Both together. Hardest on the memory controller. |

It aborts automatically if the CPU reaches 92 °C.

## ⚠️ Stop the array first

The script needs only `/dev/shm` and `/boot`. It never touches your array.

**Stop the array before running it.** If the box does lock up, an unclean shutdown with the
array stopped is essentially harmless — nothing is in flight, no parity invalidation, no
filesystem damage. There is no reason to risk your data to run a diagnostic.

(Stopping the array also stops Docker, which is a bonus if Docker is on your suspect list.)

## Dependencies

**None.** `openssl`, `sha512sum`, `dd`, `free`, `nproc`, `logger` — all ship with Unraid base.

This matters as of 2026: **Nerd Tools is no longer available**, so `stress-ng` and friends are
not a one-click install anymore. This script deliberately assumes nothing beyond the base OS.

## Writes

Only two places, both its own:
- `/dev/shm/stresstest/` — scratch, removed on exit and on interrupt
- `/boot/logs/stress-test-*.log` — the log

Never your shares. Never your array.

## Install

1. **Settings → User Scripts → Add New Script**, name it `hardware-stress-test`
2. Paste in [`script.sh`](script.sh)
3. **Stop the array**
4. **Run in Background**

Takes about 2 hours with the defaults. Tune at the top:

```bash
CPU_MINUTES=45
RAM_MINUTES=30
COMBO_MINUTES=45
RAM_TEST_GB=16      # keep well under total RAM
TEMP_ABORT=92
```

## Reading the result

**RAM corruption reported** → hardware fault. Stop here. Run Memtest86+ and start pulling DIMMs.

**Crashed mid-test** → read `/boot/logs/stress-test-*.log` after reboot. The last heartbeat is
your evidence: phase, elapsed, temperature.

**Passed clean** → be careful what you conclude. **A clean pass does not exonerate the
hardware.** Plenty of lockups are not load-triggered — if your machine dies while nearly idle,
a passing stress test tells you very little. It rules out gross thermal and load-dependent
faults, and nothing more.

**Memtest86+ (available from the Unraid boot menu) remains the definitive RAM test.** This
script complements it by testing memory *under heat and load*, which Memtest doesn't do — but
it is not a substitute.
