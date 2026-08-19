# DeepScanScriptClaude — Project Context

Read-only deep-scan bash script for a fleet of Unraid servers. Runs via the User Scripts plugin. Produces a tarball of storage-usage artifacts for file-level "where is my space going" analysis.

Current version: **v0.4.0**

## Modernization pass (v0.4.0)

- Ported `handoff_to_terminal` from hardware-stress-test — a bare User Scripts
  click (no TTY + no flags) now prints "open a terminal" + fires a
  notification instead of silently running with defaults. Any flag bypasses.
  Env-var opt-out: `UNRAID_SCRIPTS_NO_HANDOFF=1`.
- `--self-update` / `--check-update` flags; sibling `bootstrap.sh` for
  User-Scripts-side auto-update on every run.
- `notify_unraid` subject is host-prefixed `[<host>] ...`. Defined near the
  top of the file (not at line ~180 anymore) because the arg loop runs before
  the mid-file function block.
- Modernized `print_banner_modern` stdout-only banner (colour + box using
  DEMO_*); the `note`-tee'd banner below it stays plain text in the log.
- Env vars: `UNRAID_SCRIPTS_NO_HANDOFF=1`, `UNRAID_SCRIPTS_ASCII=1`,
  `NO_COLOR=1`.

## Destructive-op audit — updated

`grep -nE '^[[:space:]]*(rm|mv|dd)\b' script` shows the single-`rm` invariant
(one `rm` on `$work` intermediates before the tarball) PLUS five new `rm -f
"$tmp"` lines inside `self_update` / `check_update`. Every new `rm` targets a
`mktemp`'d file under `/tmp`. `install -m 0755 "$tmp" "$target"` inside
`self_update` writes to `/boot/...` — the ONLY write outside `$work`, gated
behind an explicit `--self-update` flag. These are documented exceptions to
the read-only invariant.

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
   Must return exactly one match. **The TUI runs BEFORE `$work`/`$LOG` are created** for exactly this reason — a cancel just `exit`s with nothing to clean up, so it never needs a second `rm`.

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
- `deepscan_tui` / `ds_render` / `ds_key` / `ds_adjust` (v0.3.3) — ANSI setup screen, only entered when `[ -t 0 ] && [ -t 1 ]`. Sets `QUICK` / `ALL_EXTENSIONS`; no new deps (`read`/`printf`/`df`/`awk`). Same stencil-width discipline as hardware-stress-test (`DS_W=67`; measure padding from the plain-ASCII stencil, never the coloured string). Cursor escapes `[ -t 1 ]`-guarded; scoped `trap … INT` cleared on ENTER.
- `notify_unraid` (v0.3.3) — best-effort `/usr/local/emhttp/webGui/scripts/notify` wrapper. Fires a **completion notification** (tarball name/size/reclaim) at the very end, for both GUI and terminal runs. Not a write to shares — doesn't affect the read-only invariant.
- `demo_collect` / `demo_report` / `demo_write_file` (v0.3.4) — server demographics (safe set: host, machine-id, unraid version, kernel, cpu+cores, ram, board, uptime, tz; no serials/MAC/flash-GUID). Sets `DEMO_*` from /proc + /sys; `demo_collect` runs in the banner, `demo_report` prints the block, `demo_write_file` writes `00-server.txt` in phase 0, and the same `DEMO_*` feed `summary.json`. For attributing a scan tarball to a box when tracking a fleet.

## Known inefficiencies (not yet fixed, low priority)

- Phase 1 runs `du -sh` then a second full `du -sb` pass over the same shares just for JSON byte values — doubles the walk cost of the "fast" phase.
- Phase 6 runs 6 separate recursive `find`s per share (one per age bucket) instead of one `find -printf` walk bucketed in a single awk pass, the way phase 5 already does.
- Phase 10 hardcodes `"0 B total, 0 links each"` for anonymous Docker volumes instead of computing a real total from `docker system df -v`.

## Remaining roadmap

- `--dry-run` flag (print what would be scanned, no I/O)
- CSV output for phase 3 matrix (easier to chart in a spreadsheet)

See `HANDOFF.md` for full current state and next steps.
