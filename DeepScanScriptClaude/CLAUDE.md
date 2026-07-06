# DeepScanScriptClaude — Project Context

Read-only deep-scan bash script for a fleet of Unraid servers. Runs via the User Scripts plugin. Produces a tarball of storage-usage artifacts for file-level "where is my space going" analysis.

Current version: **v0.3.2** (910 lines)

## Files

| File | Role |
|---|---|
| `script` | The bash entry-point — User Scripts requires this exact filename |
| `description` | One-line description shown in the User Scripts UI |
| `name` | Friendly display name (do not change) |
| `README.md` | Full project context, phase table, outputs table |
| `README-install.md` | End-user install + run instructions |
| `HANDOFF.md` | Conversation handoff — current state, roadmap, next step |
| `CLAUDE.md` | This file |

## Fleet

| Host | Array | Used | Full runtime | --quick |
|---|---|---|---|---|
| server-a | 3.7 TB | 3.7 TB | 5-10 min | ~1 min |
| server-b | 44 TB | 1.3 TB | 10-15 min | ~2 min |
| server-c | 97 TB | 53 TB | 30-60 min | ~5 min |

Deploy path: `/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/script`

## Hard constraints — never violate

1. **Read-only.** No `mv`, no `dd`. Exactly ONE `rm` line, and it must only touch intermediate files inside `$work`. Verify after every edit:
   ```
   grep -nE '^[[:space:]]*(rm|mv|dd)\b' script
   ```
   Must return exactly one match.

2. **Self-contained.** Only tools that ship with Unraid base: `find`, `awk`, `sort`, `du`, `tar`, `stat`, `df`, `mount`, `free`, `uname`, `wc`, `sed`, `tr`, `date`, `hostname`, `id`, `numfmt`, `sha256sum`, `btrfs`, `zpool`, `zfs`, `docker`, `mountpoint`. No `jq`, no package installs. `numfmt` is optional — `human()` falls back to pure awk.

3. **Single bash file.** No helper scripts; all logic inlines as functions.

4. **Single tarball.** All artifacts land in `$work` and pack into one `.tar.gz`. Mirror copy written to `script_dir/output/`.

5. **`set -u` and `set -o pipefail` are ON. `set -e` is intentionally OFF** so phases can fail without killing the script.

6. **All `find` commands must have `-xdev`** to avoid escaping across filesystem boundaries.

## Safety checks — run after every edit

```bash
bash -n script                                # syntax check
grep -nE '^[[:space:]]*(rm|mv|dd)\b' script  # must return exactly one line
shellcheck script                             # if installed; non-blocking
```

## Coding preferences

- Minimal, focused changes. Don't restructure working phases.
- No comments explaining WHAT — only WHY if non-obvious.
- Keep README.md, README-install.md, HANDOFF.md, and CLAUDE.md in sync whenever the script changes.

## Key internals

- `human()` — converts bytes to human-readable; `numfmt --to=iec` if present, pure awk fallback otherwise.
- `phase_start` / `phase_end` / `phase_skip` — write wall-clock seconds to `_timing.csv`.
- `note()` — timestamped log line, tee'd to stdout and `_run.log`.
- `exec 2>>"$ERR_LOG"` — all stderr captured globally into `_errors.log`.
- Phase 5 stores its full `find` walk to `05-raw.tsv`; phase 5b consumes it; the single `rm` at line 852 deletes it before the tarball.
- `summary.json` built with `printf` (no jq); validated with `python3` if available.
- Phase 12 loops per-mountpoint (`/mnt/user`, `/mnt/disk*`, `/mnt/cache*`, `/mnt/pool*`) before running `find -xdev` — `/mnt` itself is the parent of several separately-mounted filesystems, so a `-xdev` find rooted directly at `/mnt` can never descend into any of them. Same pattern as phase 2/14.

## Known inefficiencies (not yet fixed, low priority)

- Phase 1 runs `du -sh` then a second full `du -sb` pass over the same shares just for JSON byte values — doubles the walk cost of the "fast" phase.
- Phase 6 runs 6 separate recursive `find`s per share (one per age bucket) instead of one `find -printf` walk bucketed in a single awk pass, the way phase 5 already does.
- Phase 10 hardcodes `"0 B total, 0 links each"` for anonymous Docker volumes instead of computing a real total from `docker system df -v`.

## Remaining roadmap

- `--dry-run` flag (print what would be scanned, no I/O)
- CSV output for phase 3 matrix (easier to chart in a spreadsheet)

See `HANDOFF.md` for full current state and next steps.
