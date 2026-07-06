# Claude Code prompt — improve DeepScanScriptClaude

Paste the section below ("PROMPT START" → "PROMPT END") into Claude Code from inside this project folder:

```
cd E:\ClaudeFolder\Git\CodingProjects\DeepScanScriptClaude
claude
```

The prompt is self-contained: Claude Code has no memory of the chat that produced it, so the prompt re-states what the project is, what each file does, and what the acceptance criteria are.

---

## PROMPT START ✂---✂---✂

You are improving a read-only Unraid storage-scanning utility. The project lives in this folder. Treat `script` as the single source of truth; everything else (`description`, `name`, `README*.md`) is documentation.

### Project context

`DeepScanScriptClaude` is a bash script that drops into Unraid's **User Scripts** plugin (path on each server: `/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/`). It does a read-only walk of `/mnt/user`, produces 15 phase-output files plus two log files, packs them into one tarball, and writes the tarball to `/mnt/user/appdata/DeepScanScriptClaude/`. The tarball is uploaded back to an analysis agent for "where is my space going" reporting.

Read `README.md` for full phase-by-phase detail. Read `script` itself for the implementation. Read `README-install.md` for the end-user perspective.

Three Unraid hosts run this script today: **server-a** (3.7 TB array, 8 containers, mostly media), **server-b** (44 TB array, 1.3 TB used, Immich + ZFS), **server-c** (97 TB array, 53 TB used, 14 containers, primary services host).

### Hard constraints — do not violate

- **Read-only.** No `mv`, no `dd`. Exactly one `rm` is allowed and it must operate only on intermediate `*.tsv` files created inside the per-run working directory. Verify after every edit with:
  ```
  grep -nE '^[[:space:]]*(rm|mv|dd)\b' script
  ```
- **Self-contained.** Use only tools that ship with Unraid base + the User Scripts plugin. Currently used: `find`, `awk`, `sort`, `du`, `tar`, `stat`, `df`, `mount`, `free`, `uname`, `wc`, `sed`, `tr`, `date`, `hostname`, `id`, `numfmt`, `sha256sum`, `btrfs`, `zpool`, `zfs`, `docker`, `mountpoint`. **Do not** add jq, ncdu, fdupes, rclone, or any package that requires installation.
- **Single bash file.** The User Scripts plugin only executes `./script`. Any helper logic must inline as functions in the same file.
- **Single tarball output.** All artifacts must land in the per-run working directory (`$work`) and be packed into one `.tar.gz`. Mirror the tarball to the script's flash folder under `output/`.
- **Bash 5 / busybox-friendly.** Avoid GNU-only flags where a POSIX equivalent works. The hosts run Slackware-based Unraid with the GNU coreutils, so most `--long-option` flags are fine, but err on the side of portable.
- **Idempotent.** A re-run on the same host must not corrupt previous output. Use a per-run subdirectory keyed on `$(hostname)-$(date +%Y%m%d-%H%M)`.
- **Pre-flight + dual logs preserved.** The current script has a working pre-flight check block, `_run.log` (timestamped progress + per-phase elapsed time), and `_errors.log` (stderr capture). Do not regress those.
- **Safety re-check after edits:**
  ```
  bash -n script         # syntax
  shellcheck script      # if installed; non-blocking
  grep -nE '^[[:space:]]*(rm|mv|dd)\b' script   # exactly one rm in phase 8 cleanup
  ```

### What needs to change — task list

Implement every numbered item below. Treat each as an acceptance criterion. If anything is unclear, prefer the more conservative implementation and add a comment in `script` explaining the trade-off.

#### 1. New phase: Large File Dossier (`05b-largest-files-detailed.txt`)

Currently phase 5 produces a flat list of files ≥1 GiB. Replace its sister output with a richer dossier that splits files into three categories the user can act on differently.

**Inputs:** the same `find /mnt/user -xdev -type f -size +1024M` walk you already do in phase 5. Reuse the result; do not walk twice.

**For each file ≥1 GiB, collect:**
- Size in GiB (2 decimal places)
- mtime in `YYYY-MM-DD HH:MM` (use `date -d "@<unix_ts>"` or `stat -c '%y'` truncated)
- Parent directory name (just the immediate parent — the user will paste this into an *arr search box)
- Filename
- Full path
- Category, determined by path matching in this priority order:
  1. **`vm`** → path contains `/mnt/user/domains/` OR filename matches `*.qcow2`, `*.vmdk`
  2. **`iso`** → path starts with `/mnt/user/isos/` OR filename matches `*.iso`
  3. **`system`** → path starts with `/mnt/user/system/` OR filename is exactly `docker.img` or `libvirt.img`
  4. **`appdata`** → path starts with `/mnt/user/appdata/`
  5. **`media-tv`** → path contains `/tv/` (case-insensitive)
  6. **`media-movie`** → path contains `/movies/` or `/media/` (case-insensitive)
  7. **`temp`** → path contains `/torrents/`, `/usenet/`, `/incomplete/`, `/.unmanic/`
  8. **`other`** → none of the above

**Emit three sections to `05b-largest-files-detailed.txt`:**

```
=========================================================================
 SECTION A — Media files (manage these through your *arr stack)
=========================================================================
 Use the "Title" column to search in Radarr / Sonarr / Lidarr.
 Once located, "Manage" → "Delete files" from the WebUI rather than
 deleting on disk, so the *arr database stays in sync.

  Size   mtime              Title                              File
 ------  -----------------  ---------------------------------  --------------------
 20.88   2024-01-03 14:22   Some Movie (2024)                   Some.Movie.2024.WEBDL-2160p.mkv
                            (full path: /mnt/user/data/media/movies/Some Movie (2024)/Some.Movie.2024.WEBDL-2160p.mkv)
 ...

=========================================================================
 SECTION B — System / ISO / VM / appdata files
=========================================================================
 Decide per-row whether to delete. Use the action hint as a starting
 point; verify with `lsof` or container status before removing.

  Size   mtime              Category   Full path                              Action hint
 ------  -----------------  ---------  -------------------------------------  --------------------------
 40.00   2026-04-25 12:34   system     /mnt/user/system/docker/docker.img     Loop file. Migrate to directory mode (How-To §5)
 5.26    2023-06-15 09:11   iso        /mnt/user/isos/win_server_2019.iso     Install media. Delete if newer build exists.
 ...

=========================================================================
 SECTION C — Other / unrecognised
=========================================================================
 Files >=1 GiB that did not fit any known category. Inspect manually.

  Size   mtime              Full path
 ------  -----------------  -----------------------------------------------
 ...
```

**Action-hint lookup table** (hard-code these strings keyed by filename match — keep the table inside an awk script or a bash associative array):

| Match (filename or path tail) | Action hint |
|---|---|
| `docker.img` | `Loop file. Migrate to directory mode to reclaim allocated-but-unused space (How-To §5).` |
| `libvirt.img` | `VM definition store. Tiny by design; keep at default 1 GiB.` |
| `*.iso` under `/mnt/user/isos/` | `Install media. Delete if you have a newer version, no longer need that OS, or have a master copy elsewhere.` |
| `*.qcow2`, `*.vmdk`, `*.img` under `/mnt/user/domains/` | `Live VM disk. NEVER delete while the VM is defined; remove the VM in Settings → VMs first.` |
| Anything under `/mnt/user/appdata/<container>/...` | `Container working data for "<container>". Stop the container before touching. Use appdata.backup to snapshot first.` |
| Anything under `/torrents/`, `/usenet/` | `Download staging file. Likely safe to delete after the *arr has imported it AND your torrent client has stopped seeding.` |

For media files, do NOT add an action hint — the user has said they will manually triage via *arr.

**Sorting:** within each section, sort by size descending.

**Encoding:** plain ASCII only. Strip any control characters from filenames (some media has em-dashes etc — keep those, but reject `\t`, `\n`, `\r` to keep the table aligned).

#### 2. `--quick` flag

Add option parsing at the top of the script. Recognised flags:

- `--quick` — skip phases 6 (age histogram) and 8 (duplicate finder). Print `[SKIP]   Phase N (--quick)` in `_run.log` for each skipped phase.
- `--help` / `-h` — print usage and exit 0.
- Unknown flag — print error and exit 2.

The User Scripts plugin lets users append arguments in the WebUI, so `--quick` is the path to a 60-second iteration cycle.

Default behaviour with no flags is unchanged.

#### 3. Duplicate finder improvements (phase 8)

Currently phase 8 hashes every file ≥100 MiB whose size matches another file. Two improvements:

**3a. Skip hardlinked pairs.** Before hashing, compute `stat -c '%i'` (inode) and `stat -c '%d'` (device) for each candidate. Files sharing the same inode and device are already hardlinks — they aren't wasting space. Drop them from the candidate list before the sha256 pass and note the count in `_run.log`:

```
[HH:MM:SS]     Phase B: 18 size-collision pairs, 0 already hardlinked, 18 to sha256
```

**3b. Extension allow-list.** By default, only run sha256 against files whose extension matches one of:

```
mp4 mkv avi mov m4v ts webm iso img qcow2 vmdk zip tar tar.gz tgz 7z rar
```

Files with other extensions can still be flagged by size collision in a separate section of `08-duplicates.txt`:

```
=== Section 1: SHA-256-confirmed duplicates (media + archive + image extensions) ===
... existing format ...

=== Section 2: Size-only collisions (other extensions, NOT verified by sha256) ===
... list pairs with same size but different extensions ...
```

Add a `--all-extensions` flag to opt out of the filter (default off).

#### 4. Phase 6 — emit bytes per age bucket, not just file count

Today `06-age-histogram.txt` shows a 6-column table of file *counts* per share. That's useful for "is this share active?" but useless for "what's reclaimable?" because 553 small files older than 2 years might be 50 MB total while 56 new files might be 600 GB.

Emit two stacked tables. The existing count table stays; append a second table with the same rows/columns but summed bytes (use `find -printf '%s\n'` then `awk` sum).

Format:

```
=== File counts (existing) ===
share         >2yr    1-2yr   6-12mo   3-6mo   1-3mo   <1mo
appdata       3345    3387    123      34      761     368
...

=== Bytes per bucket (NEW; human-readable, e.g. 1.6T / 12G / 250M) ===
share         >2yr    1-2yr   6-12mo   3-6mo   1-3mo   <1mo
appdata       142M    87M     8.2M     1.1M    340M    44M
data          1.6T    12G     900M     0       4.8G    0
...
```

#### 5. Phase 10 — collapse the dangling-volume noise

Currently phase 10 lists all 142+ anonymous Docker volumes individually, all reporting 0 B / 0 links. Replace that block with one summary line:

```
Anonymous local volumes: 142 entries, 0 B total, 0 links each
  (run `docker volume prune` to remove)
```

Keep listing named volumes (e.g. `binhex-shared`) and any non-zero-size volumes.

#### 6. New file: `summary.json`

At the very end of the run (just before packing the tarball), emit a small JSON file with key facts so future tooling can parse runs programmatically:

```json
{
  "host": "server-a",
  "stamp": "20260510-2044",
  "runtime_seconds": 1085,
  "script_version": "0.3.0",
  "preflight": { "passed": true, "warnings": 0 },
  "shares": {
    "appdata": { "size_bytes": 1395864371, "files_under_1mo": 368 },
    "data":    { "size_bytes": 2087843762176, "files_under_1mo": 0 },
    ...
  },
  "largest_file_bytes": 42949672960,
  "largest_file_path": "/mnt/user/system/docker/docker.img",
  "duplicates": { "pairs": 18, "reclaimable_bytes": 27905109605 },
  "docker": { "containers": 10, "images": 10, "dangling_volumes": 142 },
  "errors_log_lines": 0
}
```

Build it inline with `printf` / `awk` — no `jq` dependency. Validate at the end with a quick `python3 -c 'import json,sys; json.load(open(sys.argv[1]))' summary.json` if `python3` exists; warn if missing or malformed.

Add a `script_version` constant near the top of the script and bump it to `0.3.0` for this release.

#### 7. New file: `_timing.csv`

Emit a CSV of per-phase wall-clock seconds for trend-analysis across runs:

```
phase,name,seconds
0,system_overview,0
1,share_totals,5
2,disk_top_dirs,1
3,share_disk_matrix,0
4,share_top_dirs,6
5,largest_files,6
5b,large_file_dossier,1
6,age_histogram,39
7,extensions,7
8,duplicates,1032
9,pools,0
10,docker,24
11,vm_images,0
12,trash,0
13,logs,5
14,snapshots,0
```

Include both phases 5 and 5b. If `--quick` was used, emit `-1` for the skipped phase's seconds.

#### 8. Phase 5b synergy — hardlink-anomaly hint

While building the large-file dossier, for each media file also check `stat -c '%h'` (hard-link count). If `nlink > 1`, note `[HL ×N]` next to the entry in section A. That hints at correctly-hardlinked imports. If nlink == 1 for a media file AND a same-size file exists in `/mnt/user/data/torrents/complete/` or `/mnt/user/data/usenet/complete/`, that is the signature of a *failed* hardlink and worth surfacing — but do not duplicate work with phase 8; just emit a count in `_run.log`:

```
[HH:MM:SS]   Phase 5b: 18 likely-failed-hardlink candidates (see Section A "no HL" rows)
```

#### 9. Final summary line — add reclaim estimate

Today the final summary prints runtime, tarball size, SMB path, and `_errors.log` line count. Append one new line:

```
  Reclaim estimate (rough): 31 GiB docker.img + 26 GiB duplicates + 0.5 GiB ISO drift = ~58 GiB
```

Build the number from `summary.json`. Pull `docker.img` allocated-vs-used delta from `docker system df -v` (size of /var/lib/docker.img minus reported `Size` of `/var/lib/docker`). Pull duplicate reclaim from `summary.json.duplicates.reclaimable_bytes`.

#### 10. README updates

Reflect every change above in `README.md`:

- Phases table: add row 5b.
- Pre-flight table: unchanged.
- Add a "CLI flags" section after "Pre-flight checks": document `--quick`, `--all-extensions`, `--help`.
- New section "Outputs" listing every file the tarball contains and a one-line description of each, including the new `summary.json` and `_timing.csv`.
- Roadmap section: remove `--quick`, JSON summary, and "Filter the duplicate finder by extension" (now implemented). Keep `--dry-run` and the share×disk CSV idea as remaining roadmap.
- Bump documented `script_version` references.

Reflect any user-facing change in `README-install.md` too (the user sees this when they install on a new server).

### Test plan

After all edits, run this checklist locally — do not push to the Unraid servers until each passes:

1. `bash -n script` — clean.
2. `grep -nE '^[[:space:]]*(rm|mv|dd)\b' script` — exactly one match in phase 8 cleanup, with a comment explaining what it removes.
3. `shellcheck script` if installed — fix any error/warning that does not require introducing a non-Unraid tool.
4. Read through every `find` command. Confirm `-xdev` is present on every walker so the script doesn't escape into other filesystems.
5. Set `set -u` and `set -o pipefail` near the top if not already present. Verify the script still completes a clean dry-run on a small dataset.
6. Mentally execute the script with `/mnt/user/` empty — the pre-flight should still pass (it currently does) and all phases should produce small or empty output files without failing.
7. Mentally execute with `--quick` — phases 6 and 8 must be skipped, every other phase must run, `_timing.csv` must contain `-1` for the two skipped phases, `summary.json.runtime_seconds` must still be valid, and the tarball must still be produced.
8. Mentally execute with no `numfmt` available — pre-flight warning fires, but phase 3 (which currently uses `numfmt --to=iec`) falls back to bytes or skips gracefully. Add a small `human()` helper function that uses `numfmt` if available, else falls back to a pure-bash conversion.

### What to deliver

Edit only the files in this folder:
- `script` (the entry point)
- `README.md`
- `README-install.md`
- `description` (only if a phrasing change is warranted)
- `name` (do not change)

Do NOT add new files other than what `script` itself writes inside the per-run working directory.

Do NOT change the User-Scripts-plugin folder convention. The folder name (`DeepScanScriptClaude`) and the entry filename (`script`) are load-bearing.

When done, print a short summary of every change you made. Bump `script_version` to `0.3.0`.

## PROMPT END ✂---✂---✂

---

## Why these specific recommendations

A short justification of each, so you can sanity-check before pasting:

| # | Task | Why |
|---|---|---|
| 1 | Large File Dossier | You asked for it explicitly — split media (use *arr to manage) from system files (manual delete) with action hints |
| 2 | `--quick` flag | Phase 8 is 95% of runtime; iterating on the rest of the script in 60 s instead of 18 m is a huge win |
| 3a | Skip hardlinked pairs in phase 8 | False positives: properly hardlinked imports show up as "duplicates" today even though they share an inode |
| 3b | Extension allow-list in phase 8 | Plex metadata, browser caches in appdata, etc. cause size-collision false positives; restricting to media/archive extensions tightens the signal |
| 4 | Bytes-per-age-bucket | "553 files older than 2 yr" is useless without their size. Surfaces archive candidates directly |
| 5 | Collapse Docker volume noise | The 142 dangling volumes blow up `10-docker.txt` and crowd out the useful container info |
| 6 | `summary.json` | Future runs / agents can diff structurally instead of with `diff` |
| 7 | `_timing.csv` | Phase-time trend visibility across runs — useful if a server slows down |
| 8 | Hardlink anomaly hint | Surfaces the "Radarr is copying instead of hardlinking" pattern proactively, without waiting for phase 8 |
| 9 | Reclaim-estimate summary line | One number the user can act on immediately at the end of every run |
| 10 | README updates | Keep docs in sync with implementation |

If any of these don't match what you want, edit the prompt before pasting. The README inside this folder is the source of truth for current behaviour.
