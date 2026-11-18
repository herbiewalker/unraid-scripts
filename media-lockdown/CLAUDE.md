# media-lockdown — Project Context

Interactive+scheduled Unraid tool: finds executables/scripts/disguised binaries in user-chosen media
folders and defuses them. Single bash file (`script.sh`), sibling `bootstrap.sh`. Current version **v0.1.0**.

## Files

| File | Role |
|---|---|
| `script.sh` | The bash entry-point (single file, all logic inlined) |
| `README.md` | Front door: what it will/won't do, usage, install, defence in depth |
| `CHANGELOG.md` | Per-tool version history |
| `HANDOFF.md` | Current state, never-yet-verified list, next steps |
| `bootstrap.sh` | Self-updater bootstrap for User Scripts |
| `CLAUDE.md` | This file |

## Hard constraints — never violate

1. **Never delete.** HIGH items are `mv`'d to `$WORK_DIR/quarantine/<stamp>/` with a `MANIFEST.tsv`.
2. **Never alter write bits, ownership, or directory modes; never `chattr`.** Only `chmod a-x,u-s,g-s` on regular
   files. Replacing/upgrading media (Radarr/Sonarr) and Plex/Jellyfin scans must keep working.
3. **`--min-age` is sacred:** every `find` carries `-mmin +N`, and `apply_fix` re-checks `still_old_enough` per file.
4. **Folders are user-chosen.** `path_problem` refuses appdata/system, `/mnt/diskN`, `/mnt/cache*`, `/mnt/user0`,
   too-shallow roots, and the tool's own work dir. Don't weaken it.
5. `set -u` and `pipefail` ON, `set -e` OFF. Single file, no sourced libraries. `printf '%s\0' "${!ARR[@]}"` on an
   empty array emits one empty record — always guard.

## Write surface (deviation from the repo's read-only norm — keep documented)

chmod/mv inside picked folders (only via `fix`) · `$WORK_DIR` (logs, quarantine) · flash config via `w`/`--save` ·
`install` to `/boot/...` only via `--self-update`.

## Brand mark

Header ASCII block + inlined `brand_banner_modern` (TTY only) + footer line, `BRAND_SIGIL` in notification subjects.
Canonical: `DevPlaybook/templates/brand/brand.sh`. Handoff for bare User Scripts click; `demo_collect` shared shape.

## Never yet verified on live Unraid

`docker inspect` template output on 7.x · `notify` flags · TUI under the webGUI terminal (ttyd) · `/mnt/user` fuse
`find -perm`/`-mmin` semantics at scale · `--deep` runtime on a 100 TB array.
