<div align="center">

# DeepScanScriptClaude

### A read-only deep-scan of your Unraid array — one tarball, full file-level "where is my space going" analysis.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](script)
[![Platform](https://img.shields.io/badge/Unraid-7.2%2B-e8a33d?logo=unraid&logoColor=white)](#installing)
[![Release](https://img.shields.io/badge/release-v0.3.2-success)](script)
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
| 0 | System overview (`df`, `mount`, `free`, share list) | `00-*.txt` |
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

See [README-install.md](README-install.md) for full end-user steps. The short version:

1. Copy this folder to `/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/`
2. Unraid webGUI → **Settings → User Scripts** → refresh → **DeepScanScriptClaude** → **Run Script** (or **Run in Background** for large arrays)
3. Optional flags in the **Arguments** field: `--quick` (skip phases 6+8), `--all-extensions` (hash every file type in the duplicate finder), `--help`

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
| `summary.json` | Host, runtime, per-share sizes, largest file, duplicate-reclaimable bytes, Docker counts, error count. |

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

**v0.3.2.** Written and reviewed, not yet confirmed run against a live server. Remaining roadmap: a `--dry-run` flag, and CSV output for the phase 3 share×disk matrix.

## License

MIT — see [LICENSE](../LICENSE).
