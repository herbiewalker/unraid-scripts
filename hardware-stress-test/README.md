# hardware-stress-test

CPU + RAM stress test for Unraid, built around **crash forensics** and the
hardware's **own error counters** — not a pass/fail score.

## The problem it solves

When an Unraid box hard-locks — kernel dead, BMC still responding, power cycle
required — the syslog dies with it. Unraid's `/var/log` is **tmpfs**: it lives in
RAM. You reboot, and the evidence that would have explained the crash is gone.

Standard stress tools are built for a machine that survives the test. They print a
result at the end. If your box freezes solid at minute 37, you get nothing — not
even the knowledge that it froze at minute 37.

**So the real product of this script is not the pass/fail. It is the heartbeat
trail.** Every few seconds it writes phase, elapsed time, CPU temperature, load,
memory, and live ECC error counts to:

- **`/boot/logs/stress-test-<timestamp>.log`** — on the flash drive, `sync`'d
  immediately, so it **survives a hard lockup**
- **syslog** — which also reaches your remote syslog server, if you have one

If the machine dies, you reboot and read the last line. It tells you which phase it
was in, how far in, how hot it was, and whether ECC was already logging errors.

## What actually finds faults

The stress load only *provokes* a fault. The evidence comes from counters the
hardware keeps itself — which is what separates this from a checksum toy:

| Source | What it catches |
|---|---|
| **EDAC / ECC** (`/sys/devices/system/edac/mc/*`) | The authoritative memory-fault signal on ECC hardware. Rising corrected-error (CE) count under load = a DIMM going bad; any uncorrectable (UE) = the machine is unwell. Checked live — a UE **aborts immediately**. |
| **MCE** (dmesg) | Machine Check Exceptions — CPU, cache, and bus faults. |
| **Thermal throttling** (`/sys/.../thermal_throttle/*`) | Separates "hot" from "so hot the CPU is protecting itself" — a throttle event invalidates any timing result. |
| **tmpfs checksums** | Our own RAM pattern-verify. The fallback for **non-ECC** boxes, and the weakest of the four: it only sees a flip that lands in our pages while we hold them. |

On a non-ECC box only the last one is available, and the script says so plainly in
its verdict. On ECC hardware you get all four.

## Why it runs natively, not in Docker

Deliberate. If you're chasing an unexplained lockup, **Docker is a suspect** —
Unraid's own release notes point at Docker custom-network problems as a first-line
cause of "unexplained crashes." Stressing the CPU *through* a container means a
crash tells you nothing about whether it was the CPU or the container runtime. This
runs on bare Unraid. One variable.

## The phases

| Phase | Standard | What it does |
|---|---|---|
| **1 — CPU only** | 45 min | AES-256 encrypt loop on half the cores, SHA-512 on the other half. Exercises the crypto units, the integer path, and generates real heat. (Uses `stress-ng --cpu-method all` instead, if it's installed.) |
| **2 — RAM verify** | 30 min | Writes a known pattern into `/dev/shm` (tmpfs = RAM), then re-checksums it in a loop. A mismatch = a bit flipped. |
| **3 — CPU + RAM** | 45 min | Both together. Hardest on the memory controller. |

Three built-in profiles: **Quick** (~16 min smoke test), **Standard** (~2 h), and
**Burn-in** (~7.5 h, for new or suspect hardware). Or pick phases and durations
individually.

## Two ways to run it

**From a terminal (SSH, or the Unraid web terminal) — interactive setup screen:**

```
bash /boot/config/plugins/user.scripts/scripts/hardware-stress-test/script.sh
```

You get an arrow-key setup screen: pick a profile, toggle phases, set the RAM size
and abort temperature, and watch a **live preflight panel** (root, temperature
source, ECC presence, array state) and a running time estimate update as you edit.
It won't let you start while a red preflight item is unresolved.

```
┌─ hardware-stress-test v0.2.0 ─────────────────────────────────────┐
│  PROFILE    < Standard >    Quick . Standard . Burn-in . Custom   │
│  PHASES                                                           │
│    [x]  1  CPU only                45 min                         │
│    [x]  2  RAM verify              30 min                         │
│    [x]  3  CPU + RAM               45 min                         │
│  RAM test size   < auto >    10 G   (32 G total, shm free 16 G)   │
│  Abort at        <   92 > C                                       │
├─ PREFLIGHT ───────────────────────────────────────────────────────┤
│  v CPU temp via hwmon (k10temp)   v ECC/EDAC present (amd64)      │
│  v array is STOPPED                                               │
├───────────────────────────────────────────────────────────────────┤
│  Est. runtime  2h 02m      up/dn move  l/r change  ENTER start    │
└───────────────────────────────────────────────────────────────────┘
```

**From Settings → User Scripts — no setup screen.** User Scripts runs the script
with no terminal attached, so there's nowhere to draw an interactive screen (and a
prompt there would hang the job). It uses the Standard profile, or whatever flags
you set in the script's arguments box. Add `--yes` to skip prompts.

Either way: **stop the array first** (see below).

## Configuration flags

```
--profile quick|standard|burn-in    Preset (default: standard)
--phases 1,2,3                       Which phases to run
--cpu-min / --ram-min / --combo-min  Per-phase minutes
--ram-gb <n|auto>                    RAM to exercise (auto = sized to the box)
--temp-abort <c>                     Abort temperature (default: 92)
--heartbeat <n>                      Heartbeat seconds (default: 15)
--engine auto|builtin|stress-ng      Load engine (auto uses stress-ng if present)
--stop-on-error                      Stop on the first RAM/ECC error
--preflight-only                     Print the preflight checks and exit
--no-tui / --yes                     Skip the setup screen / skip confirmation
--override-array                     Run even if the array is started (risky)
--version / --help
```

`--ram-gb auto` takes the smaller of 80 % of free tmpfs and a third of physical RAM
— enough to exercise memory without inviting the OOM killer, whose kill looks
exactly like the lockup you're trying to diagnose.

## ⚠️ Stop the array first

The script needs only `/dev/shm` and `/boot`. It never touches your array.

**Stop the array before running it.** If the box does lock up, an unclean shutdown
with the array stopped is essentially harmless — nothing is in flight, no parity
invalidation, no filesystem damage. There is no reason to risk your data to run a
diagnostic. (Stopping the array also stops Docker, a bonus if Docker is on your
suspect list.) The preflight **refuses to start with the array running** unless you
pass `--override-array`.

## Dependencies

**None required.** Temperature is read straight from `/sys/class/hwmon`, so even
lm-sensors is optional. `openssl`, `sha512sum`, `dd`, `free`, `nproc`, `logger`,
`dmesg` all ship with Unraid base.

If `stress-ng`, `memtester`, or `sensors` happen to be installed, the script uses
them (they're better at their jobs) — but nothing here needs them. This matters as
of 2026: **Nerd Tools is no longer available**, so `stress-ng` and friends are not a
one-click install anymore.

## Writes

Only its own scratch and its logs — never your shares, never your array:

- `/dev/shm/hardware-stress-test/` — scratch, removed on exit, on interrupt, **and
  on any unexpected error** (EXIT trap)
- `/boot/logs/stress-test-*.log` — the heartbeat log
- `/boot/logs/stress-test-*.json` — machine-readable summary

A lock file (`/var/run/hardware-stress-test.lock`) prevents two runs from sharing
`/dev/shm` and corrupting each other's results.

## Reading the result

The run ends with a **verdict** and writes a `summary.json`. Exit codes:

| Code | Meaning |
|---|---|
| `0` | Completed, no hardware errors detected |
| `1` | Preflight failed — did not run |
| `2` | **Hardware error** — ECC uncorrectable, MCE, or RAM checksum mismatch |
| `3` | Aborted on temperature |
| `130` | Interrupted |

- **Hardware error (exit 2)** → stop here. Memory/CPU errors are not a software
  problem. Run Memtest86+ and start pulling DIMMs.
- **Aborted on temperature (exit 3)** → the abort *works now* (it did not in
  v0.1.x). Fix your cooling before drawing any other conclusion.
- **Crashed mid-test** → read `/boot/logs/stress-test-*.log` after reboot. The last
  heartbeat is your evidence: phase, elapsed, temperature, ECC counts.
- **Passed clean (exit 0)** → read it narrowly. **A clean pass does not exonerate
  the hardware.** Plenty of lockups are not load-triggered; if your machine dies
  while nearly idle, a passing stress test tells you very little.

**Memtest86+ (from the Unraid boot menu) remains the definitive RAM test.** This
script complements it by testing memory *under heat and load* and by reading the
ECC counters live — but it is not a substitute.
