<div align="center">

# media-lockdown

### Find and defuse executables hiding in your Plex/Jellyfin library — without ever getting in the *arr stack's way.

</div>

Sonarr/Radarr grab files from the internet and drop them in the folders Plex and Jellyfin read.
Occasionally one of those downloads is not media: an `.exe`, a `.sh`, a `.lnk`, or a Windows
executable renamed `Movie.2160p.mkv`. `media-lockdown` finds those in the folders **you pick**,
and (optionally) neutralises them.

## What it will and will not do

| Never | Always |
|---|---|
| Delete anything (HIGH items are *moved* to a quarantine batch with a restore manifest) | Skip files modified in the last `--min-age` minutes (default 60) so imports/upgrades in flight are never touched |
| Change write permission, ownership, or folder modes | Leave `*arr` upgrades (1080p → 4K), renames, deletes and Plex/Jellyfin scans working exactly as before |
| Use `chattr +i`, read-only remounts, or anything that blocks replacing media | Re-check each file's age again right before changing it |
| Touch anything outside the folders you pick | Refuse appdata/system folders, `/mnt/diskN`/`/mnt/cache` paths and over-broad roots |

Findings: **HIGH** = dangerous extension (`.exe .sh .bat .jar .py .lnk …`), setuid/setgid, or (with `--deep`)
a Windows EXE / Linux binary / `#!` script disguised as media · **MED** = exec bit set on a file ·
**REVIEW** = unknown extension, leftover archive, symlink (reported only).

`fix` quarantines HIGH and strips exec bits (`chmod a-x,u-s,g-s`) from MED. `--strict` also quarantines unknown file types.

## Use it

```bash
bash script.sh                 # interactive TUI: pick folders → review → run
bash script.sh --discover      # which folders do my Plex/Jellyfin/*arr containers use?
bash script.sh --docker-audit  # privileged containers, read-write media mounts
bash script.sh --scan --notify # unattended report (uses saved folders)
bash script.sh --fix --apply   # unattended fix
bash script.sh --list          # quarantine batches
bash script.sh --restore /mnt/user/appdata/media-lockdown/quarantine/<stamp>/MANIFEST.tsv
```

In the TUI: **p** pick folders (browser — `★` marks folders your media containers use, **g** jumps between them),
**a** scan/fix, **d** deep, **s** strict, **m** min-age, **e** skip-list, **w** save as this server's defaults, **ENTER** run.
Saved defaults live in `/boot/config/plugins/media-lockdown/media-lockdown.conf` (per server).

## Install

Paste [`bootstrap.sh`](bootstrap.sh) into **Settings → User Scripts → Add New Script**, as with the other tools.
A bare GUI click hands off to a terminal (the folder picker needs one). Schedule weekly with
`--scan --deep --notify` after saving your folders once with **w**.

## Defence in depth (outside this script)

1. Mount media **read-only** into Plex/Jellyfin (`:ro`) if you don't store artwork/`.nfo` in the library — `--docker-audit` shows where it isn't.
2. Turn on *arr "reject dangerous / blocked file extensions" and your download client's unwanted-extension list.
3. Keep downloads and finished media in separate folders; point this tool at the finished-media folders only.
4. Don't open library files from a Windows PC on the same SMB share without checking the extension.

## Exit codes

`0` clean · `1` usage/config · `2` HIGH findings (scan) · `3` fix finished with errors

## Status

Unit-tested on a Linux sandbox against a synthetic library (scan, fix, restore, excludes, deep scan, TUI via pty,
config save/load, upgrade-style overwrite/rename/delete after fix). **Never yet run on live Unraid.** Unlike the
other tools in this repo this one *writes* — to the folders you pick (chmod/move), to
`/mnt/user/appdata/media-lockdown/` (logs + quarantine) and, with **w**, to the flash config — so run `--scan`
first on each server.
