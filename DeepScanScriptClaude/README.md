<div align="center">

# DeepScanScriptClaude

### A read-only deep-scan of your Unraid array — one tarball, full file-level "where is my space going" analysis.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](script)
[![Platform](https://img.shields.io/badge/Unraid-7.2%2B-e8a33d?logo=unraid&logoColor=white)](#installing)
[![Release](https://img.shields.io/badge/release-v0.4.0-success)](script)
[![Writes](https://img.shields.io/badge/writes-none-critical)](#design-constraints)

Drops into the Unraid **User Scripts** plugin, walks `/mnt/user`, and packs 16 phases of storage-usage detail into a single tarball you can hand off for analysis — largest files, duplicates, file-age histogram, BTRFS/ZFS/Docker/VM stats, trash locations, oversized logs.

</div>

## Why it exists

- 🔒 **Read-only, provably.** Exactly one `rm` in the whole script, and it only ever touches intermediate files inside its own per-run working directory — never your shares. A one-line `grep` (see [Editing](#editing)) verifies this after every change.
- 📦 **Self-contained.** Only tools that ship with Unraid base (`find`, `awk`, `du`, `tar`, `btrfs`, `zpool`, `docker`, …) — no `jq`, no package installs.
- 🖥️ **Fleet-tested design.** Sized against three real servers: a 3.7 TB array that finishes in minutes, and a 97 TB array (53 TB used) where the duplicate finder alone can take the better part of an hour — hence `--quick`.
- 📋 **Pre-flight checked.** Verifies root, array mount, output writability, free space, and every tool it depends on before touching anything, with hard-fail vs. warn clearly distinguished.
- 🗂️ **One artifact.** Every phase's output lands in a single `.tar.gz`, typically 5–50 MiB, small enough to hand back for analysis.

## Phases

| # | Phase | Output |
|---|---|---|
| 0 | System overview (`df`, `mount`, `free`, share list) + **server demographics** (host, machine-id, Unraid version, kernel, CPU, RAM, board, uptime) | `00-*.txt`, `00-server.txt` |
| 1 | Per-share total size | `01-share-totals.txt` |
| 2 | Per-disk top-level dirs | `02-disk-*.txt` |
| 3 | Share × disk usage matrix | `03-share-disk-matrix.txt` |
| 4 | Top 30 dirs per share (depth 1-2) | `04-share-*-top-dirs.txt` |
| 5 | Top 100 files ≥1 GiB server-wide | `05-largest-files.txt` |
| 5b | Large file dossier — media / system-ISO-VM-appdata / other, with action hints | `05b-largest-files-detailed.txt` |
| 6 *(skippable)* | File-age histogram — counts + bytes per bucket | `06-age-histogram.txt` |
| 7 | Bytes by file extension (top 25) | `07-extensions.txt` |
| 8 *(skippable)* | Duplicate finder — hardlink-aware, SHA-256-confirmed | `08-duplicates.txt` |
| 9 | BTRFS / ZFS pool stats | `09-pools.txt` |
| 10 | Docker summary, container sizes, volumes | `10-docker.txt` |
| 11 | VM image inventory | `11-vm-images.txt` |
| 12 | Trash / Recycle Bin / lost+found / @eaDir | `12-trash.txt` |
| 13 | Log files >50 MiB | `13-logs.txt` |
| 14 | BTRFS subvolumes, ZFS snapshots | `14-snapshots.txt` |
| 15 | Pack into `storage-scan-<host>-<stamp>.tar.gz` + mirror to flash | tarball |

Plus `summary.json` (machine-readable key metrics) and `_timing.csv` (per-phase wall-clock seconds) alongside the two log files below.

## Installing

See [README-install.md](README-install.md) for full end-user steps. Two paths:

**A. Auto-update via bootstrap (recommended).** Paste [`bootstrap.sh`](bootstrap.sh) into User Scripts once. Every run pulls the latest `script` from GitHub (rate-limited to 1h, `bash -n`-checked, cached to flash with fallback). An Unraid notification fires when the cached version changes. No more SSH-and-copy on each release.

**B. Plain paste.** Copy this folder to `/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/` and add via **Settings → User Scripts**. `--self-update` still works for opt-in refreshes.

Optional flags in the User Scripts **Arguments** field: `--quick` (skip phases 6+8), `--all-extensions` (hash every file type in the duplicate finder), `--check-update`, `--self-update`, `--help`.

### Two ways to run it

**From the User Scripts GUI** — a **bare click with no flags** now hands you off to a terminal: prints the exact command to run and fires an Unraid notification, then exits without touching the array. (This is the same pattern used by [`hardware-stress-test`](../hardware-stress-test), so the interactive setup can never accidentally be requested from a log-pane with no keyboard.) **Passing ANY flag** in the Arguments field bypasses the handoff — `--quick` or `--all-extensions` or `--help` all count. When the scan finishes it fires an **Unraid notification** with the tarball name, size, and rough reclaim estimate, so a long background run surfaces its result without you watching the log pane.

**From a terminal (SSH / Unraid web terminal)** — run it with no flags for an
interactive **setup screen**: arrow keys to pick Quick vs Full and toggle the
all-extensions duplicate hashing, with the host, output location, free space, and a
runtime estimate shown live.

```
bash /boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/script
```

```
┌───────────────────────────────────────────────────────────────────┐
│  MODE            < Full   >   Quick . Full                        │
│                  all 16 phases                                    │
│  All extensions  < off >                                          │
│                  hash media + archive only (faster)               │
├───────────────────────────────────────────────────────────────────┤
│ SCAN                                                              │
│  Host          server-a                                           │
│  Output        /mnt/user/appdata/DeepScanScriptClaude             │
│  Free space    412 GiB free                                       │
│  Est. runtime  ~5-60 min (depends on array size)                  │
├───────────────────────────────────────────────────────────────────┤
│  up/dn move   l/r change   ENTER start   q quit                   │
└───────────────────────────────────────────────────────────────────┘
```

The screen only appears on a real terminal. In User Scripts (no TTY), the script *either* runs with the flags you passed *or*, if you passed no flags at all, hands off to a terminal via notification — so it never silently runs the defaults when there was no keyboard to review them.

### Env vars

- `UNRAID_SCRIPTS_NO_HANDOFF=1` — silence the "open a terminal" nudge on bare GUI clicks
- `UNRAID_SCRIPTS_NO_UPDATE=1` — respected by [`bootstrap.sh`](bootstrap.sh); skip the fetch, run cached copy
- `UNRAID_SCRIPTS_ASCII=1` — fall back to ASCII glyphs (`v x ! > o ->`) on limited terminals
- `NO_COLOR=1` — disable ANSI colors

### Runtime estimates

| Server | Size of `/mnt/user` | Full run | `--quick` |
|---|---|---|---|
| server-a | 3.7 TB | 5–10 min | ~1 min |
| server-b | 1.3 TB used (44 TB allocated) | 10–15 min | ~2 min |
| server-c | 53 TB | 30–60 min — schedule off-hours | ~5 min |

The duplicate finder (phase 8) is the dominant cost on server-c.

## Logs & output

| File | Contents |
|---|---|
| `_run.log` | Timestamped `[HH:MM:SS]` progress — every phase start, file produced, elapsed time. What the User Scripts UI shows live. |
| `_errors.log` | All stderr, captured via `exec 2>>`. Empty on a clean run; a non-zero line count is flagged in the final summary. |
| `_timing.csv` | CSV of per-phase wall-clock seconds (`-1` = skipped via `--quick`). |
| `summary.json` | Server demographics (host, machine-id, Unraid version, kernel, CPU, RAM, board, uptime), runtime, per-share sizes, largest file, duplicate-reclaimable bytes, Docker counts, error count. |
| `00-server.txt` | Plain `key=value` server demographics — so an unpacked tarball is instantly attributable to a specific box when tracking a fleet. |

Output priority: `/mnt/user/appdata` → `/mnt/user/data` → `/mnt/user/Backups` → `/mnt/user/isos` → flash fallback. A mirror copy always lands in `output/` next to the script itself, so the User Scripts page can surface it directly.

## Design constraints

- **Read-only.** No `mv`, no `dd`; exactly one `rm`, scoped to intermediate working files inside the script's own per-run directory.
- **Self-contained.** No package installs; `numfmt` is optional (`human()` falls back to pure awk).
- **Single bash file.** No helper scripts — the User Scripts plugin only ever executes `./script`.
- **Every `find` uses `-xdev`**, anchored at an actual mountpoint, so a walk never escapes across filesystem boundaries.

## Editing

The whole thing is one bash file — the User Scripts plugin re-reads it on every run, no build step. After any edit:

```bash
bash -n script                                 # syntax check
grep -nE '^[[:space:]]*(rm|mv|dd)\b' script     # must show exactly one line
shellcheck script                               # if installed; non-blocking
```

## Status

**v0.4.0** (2026-08-19). Modernization pass on top of v0.3.4: `--self-update` / `--check-update`, sibling [`bootstrap.sh`](bootstrap.sh) for User-Scripts-side auto-fetch, GUI → terminal handoff for bare clicks, host-prefixed notification subjects. Remaining roadmap: a `--dry-run` flag, and CSV output for the phase 3 share×disk matrix.

## License

MIT — see [LICENSE](../LICENSE).
