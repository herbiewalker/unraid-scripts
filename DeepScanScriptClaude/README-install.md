# DeepScanScriptClaude v0.4.0 — install for User Scripts

Read-only deep scan of `/mnt/user`. Designed to run from the Unraid User Scripts plugin.
Output is saved to a user-share so it's reachable via SMB. When the scan finishes it
fires an **Unraid notification** with the tarball location. Run it instead from a
terminal (SSH / web terminal) with no flags to get an interactive setup screen — see
the main [README.md](README.md#two-ways-to-run-it).

## What this folder contains

| File | Purpose |
|---|---|
| `script` | The actual bash; User Scripts always looks for a file literally named `script` |
| `bootstrap.sh` | Optional User-Scripts-side loader — pulls latest `script` from GitHub each run |
| `description` | One-line description shown next to the entry in the User Scripts page |
| `name` | Friendly display name |
| `README-install.md` | This file |

## 1. Install (one-time, per server)

**Two paths — pick one.**

### A. Auto-update via bootstrap (recommended)

Paste [`bootstrap.sh`](bootstrap.sh) directly into a new User Scripts entry:

1. **Settings → User Scripts → Add New Script** → name it `DeepScanScriptClaude` → **Edit**
2. Paste the entire content of [`bootstrap.sh`](bootstrap.sh) → **Save Changes**
3. Done. First run will `curl` `script` from GitHub raw, `bash -n`-check it, cache it under `/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/`, and exec it. Subsequent runs re-fetch at most once an hour, fall back to the cached copy if offline, and fire an Unraid notification when the cached version changes.

Opt-out env vars: `UNRAID_SCRIPTS_NO_UPDATE=1` (skip fetch, always run cached), `UNRAID_SCRIPTS_NO_HANDOFF=1` (silence the terminal handoff).

### B. Plain paste (freeze a specific version)

Copy this entire folder to:

```
/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/
```

so that the final structure on the server is:

```
/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/script
/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/description
/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/name
```

Easiest paths:

- **SMB:** map `\\<server>\flash\config\plugins\user.scripts\scripts\` and drag-drop the `DeepScanScriptClaude/` folder.
- **WebUI Terminal / SSH:**
  ```
  cp -r /mnt/user/<some_share_with_this_folder>/DeepScanScriptClaude /boot/config/plugins/user.scripts/scripts/
  chmod +x /boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/script
  ```

The User Scripts page may need a refresh to pick up a brand-new script. To update in place, run `--self-update` (fetches latest, syntax-checks, replaces, fires a version-bump notification).

## 2. Run

WebUI: **Settings → User Scripts → DeepScanScriptClaude**

- **Run Script** — runs in the foreground with a live log window. Fine on server-a and server-b.
- **Run in Background** — recommended for server-c (the duplicate finder phase walks every file ≥100 MiB in the array).

### Pre-flight checks

Before any phase runs, the script checks itself. Critical failures abort immediately; warnings are logged and the affected phase just produces partial output.

| Check | If it fails |
|---|---|
| Running as root | Hard fail — `btrfs`, `zpool`, `docker` all require it |
| `/mnt/user` mounted and non-empty | Hard fail (empty array = warn) |
| Output directory writable | Hard fail |
| Free space <50 MiB on output destination | Hard fail |
| Free space 50–200 MiB on output destination | Warn |
| Flash drive script dir present (mirror target) | Warn — mirror skipped |
| Essential tools (`find`, `awk`, `sort`, `du`, `tar`, `stat`, `df`, `mount`, `free`, `uname`, `wc`, `sed`, `tr`, `date`, `hostname`, `id`) | Hard fail per missing tool |
| Optional tools (`numfmt`, `sha256sum`, `btrfs`, `zpool`, `zfs`, `docker`, `mountpoint`) | Warn — affected phase produces partial output |

If you see `[FAIL]` lines in the log, fix those first and re-run — the script won't proceed past a hard failure.

### Optional flags

Enter these in the **Arguments** field next to the Run button, or append them when running via SSH:

| Flag | Effect |
|---|---|
| `--quick` | Skip phases 6 (age histogram) and 8 (duplicate finder). Cuts runtime to ~1-5 min. Good for a quick first look. |
| `--all-extensions` | Hash ALL file extensions for duplicate detection (default: media + archive types only). Slower but more thorough. |
| `--self-update` | Fetch the latest `script` from GitHub, syntax-check, replace self, fire an Unraid notification. Exit. |
| `--check-update` | Compare local vs. remote version, print delta, exit. Touches nothing. |
| `--help` | Print usage and exit. |

**Note on the GUI handoff:** a User Scripts click with **no flags** at all now hands off to a terminal (prints the exact command to run and fires an Unraid notification) instead of silently running the defaults. **Any flag bypasses the handoff.** So a scheduled or on-demand User Scripts run should always pass at least `--quick` or `--all-extensions` (or `--yes`-equivalent — plain `--all-extensions` with QUICK=0 will work) so the scan actually runs. Set `UNRAID_SCRIPTS_NO_HANDOFF=1` in the User Scripts environment to disable the handoff globally.

### Estimated runtime

| Server | Full run | `--quick` |
|---|---|---|
| server-a (3.7 TB) | 5-10 min | ~1 min |
| server-b (1.3 TB used) | 10-15 min | ~2 min |
| server-c (53 TB) | 30-60 min — schedule off-hours | ~5 min |

The script is read-only — it never moves, modifies, or deletes any of your files.

## 3. Pick up the output

When the script finishes it prints something like:

```
Tarball : /mnt/user/appdata/DeepScanScriptClaude/storage-scan-<host>-<stamp>.tar.gz
Reclaim estimate (rough): 40.0 GiB docker.img + 26.3 GiB duplicates = ~66.3 GiB
Reach over SMB:
  \\<host>\appdata\DeepScanScriptClaude\storage-scan-<host>-<stamp>.tar.gz
```

The tarball is also mirrored to:

```
/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/output/
```

so you can grab it via the **flash** SMB share if `appdata` isn't mapped on your Mac/PC.

If neither share is currently exported, fetch it via SSH:

```
scp root@<host>:/mnt/user/appdata/DeepScanScriptClaude/storage-scan-*.tar.gz .
```

Or open the WebUI **Terminal** and run:

```
ls -lh /mnt/user/appdata/DeepScanScriptClaude/
```

## 4. Send the tarballs back

Drop all three tarballs (one per server) into the chat. I'll unpack them and produce the file-level "delete X to reclaim Y" report — top space hogs, age-based archive candidates, duplicate clusters, Plex/appdata bloat, VM image inventory, and remediation suggestions.

## 5. Where the output lands (priority order)

The script auto-picks the first share it finds in this list:

1. `/mnt/user/appdata` — present on every Unraid server, default choice
2. `/mnt/user/data`
3. `/mnt/user/Backups` or `BackUps`
4. `/mnt/user/isos`
5. Flash-only fallback: `/boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/`

Tarballs typically run 5-50 MiB on disk (just text files, no media is included), so the flash fallback is always safe.

## 6. Safety reminder

This script is read-only, but a sanity-check `grep` confirms it for you:

```
grep -nE '^[[:space:]]*(rm|mv|dd)\b' \
  /boot/config/plugins/user.scripts/scripts/DeepScanScriptClaude/script
```

You will see **exactly one line** — the cleanup of intermediate working files (TSVs and temp files) inside the script's own per-run directory immediately before packing the tarball. No `rm` ever touches anything under `/mnt/user/<your shares>` or any disk.
