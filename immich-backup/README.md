<div align="center">

# immich-backup

### Stop-the-stack Immich backup for Unraid — photos + appdata + compose, GFS retention, one file.

![License](https://img.shields.io/badge/license-MIT-blue)
![Platform](https://img.shields.io/badge/platform-Unraid_7.2%2B-e8a33d?logo=unraid&logoColor=white)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
![Self-contained](https://img.shields.io/badge/self--contained-no_installs-success)

**Status:** v0.1.4 — **first live run on server-b 2026-08-18** (425 GB rsync + trap-based stack restart both verified live).

</div>

---

## What & why

Backs up the live Immich stack on server-b the safe way: **stop the containers → snapshot the photos share + the appdata tree + the compose file → restart the stack → rotate old backups.** Because the containers are stopped during the copy, the Postgres data files are quiescent and the archive is a consistent restore-point without needing `pg_dump`.

Retention is Grandfather–Father–Son (default 7 daily / 4 weekly / 6 monthly) — designed to keep the [`DeepScanScriptClaude`](../DeepScanScriptClaude) stale-backup warning quiet while still bounding disk use.

- **In scope:** photos library, appdata (postgres + redis + config + model cache), docker-compose + `.env`, integrity verification, dated retention, User Scripts–friendly output.
- **Not in scope:** live/hot backups (deliberately — stopping the stack is the consistency guarantee), offsite mirroring (add rclone separately if you want it), encryption at rest (belongs to the destination, not the tool).
- **Hard constraints:**
  - **Stack always restarts** — even on Ctrl-C, script crash, or preflight failure. Enforced by a bash EXIT/INT/TERM trap. Exit code `3` is reserved for the one case this fails.
  - **Self-contained** — only tools that ship with Unraid base + docker (rsync, tar, sha256sum, awk, date, du, df).
  - **Single file** — `script.sh`, drops straight into User Scripts.
  - **Writes only to `--dest`** — no touches to shares, no writes outside the backup root or `/var/lock`.

## ⚡ Quickstart

Prerequisites: root on Unraid, docker running, an Immich stack whose containers are named `immich*`.

Full backup (default `--dest /mnt/user/data/backup_immich`, GFS 7d/4w/6m retention):

```bash
bash /boot/config/plugins/user.scripts/scripts/immich-backup/script
```

> [!WARNING]
> Whenever you run this on a **new** target for the first time (different Unraid box,
> different Immich install, different destination share), climb the ladder rather than
> jumping straight to a full run:
>
> ```bash
> script --preflight-only                                # environment checks, acts on nothing
> script --dry-run                                       # prints every action
> script --skip-photos --keep-daily 2 --keep-weekly 1 --keep-monthly 1   # smallest live scope
> script                                                 # full run
> ```

## Usage

The common commands (`--help` prints the full flag reference):

```bash
# scheduled full backup (User Scripts cron target)
script --dest /mnt/user/data/backup_immich --quiet

# skip the huge photo library and just snapshot metadata + config
script --dest /mnt/user/data/backup_immich --skip-photos

# list existing backups, sizes, and retention class
script --list --dest /mnt/user/data/backup_immich

# integrity-check a specific backup: tar readability + sha256
script --verify /mnt/user/data/backup_immich/20260818-0300
```

## What it does, phase by phase

| Phase | Action | Skippable? | Failure behaviour |
|---|---|---|---|
| **0 · Preflight** | Root check, deps, source/dest paths exist, dest writable, no other backup running, containers discoverable, enough free space | — | Aborts (`exit 1`) before touching anything |
| **1 · Stop stack** | `docker stop` each `immich*` container | `--skip-stop` | Trap restarts what got stopped |
| **2 · Appdata** | `tar czf appdata.tar.gz` over `/mnt/user/appdata_immich` | `--skip-appdata` | Marks backup FAILED, restarts stack, exit 2 |
| **3 · Compose** | `cp -a` of `/boot/config/plugins/compose.manager/projects/immich` | `--skip-compose` | Warns and continues if dir missing |
| **4 · Photos** | `rsync -aHAX --delete --numeric-ids` over the photos share | `--skip-photos` | Marks backup FAILED, restarts stack, exit 2 |
| **5 · Manifest** | `manifest.json`: versions, sizes, sha256s, server-identity block | — | Marks backup FAILED |
| **6 · Restart stack** | `docker start` each stopped container | — | **exit 3** — stack may be down, alert the user |
| **7 · Finalize** | Rename `.in-progress-YYYYMMDD-HHMM/` → `YYYYMMDD-HHMM/` (only if all phases green) | — | Otherwise the dir keeps the `.in-progress-` prefix so `--list` shows it as FAILED |
| **8 · Rotate** | GFS prune of dated dirs outside the keep window | — | Reports per-dir, doesn't abort the run |

## Retention (GFS)

Backups are dated `YYYYMMDD-HHMM/`. On every run:

- **Dailies:** last `--keep-daily N` runs (default **7**).
- **Weeklies:** last `--keep-weekly N` runs that fell on a Sunday (default **4**).
- **Monthlies:** last `--keep-monthly N` runs that fell on the 1st of a month (default **6**).

A backup that qualifies for any of the three keep sets is kept. Everything else is pruned. This mirrors the standard homelab-friendly interpretation of GFS and slots into the industry-standard 3-2-1 rule as the "1 local copy" — mirror to offsite separately if you want it (rclone against `--dest` is fine because backup directories are self-contained).

## Fresh-look TUI

```
╭──────────────────────────────────────────────────────────────────────────╮
│ immich-backup v0.1.0  ·  backup run  ·  stamp 20260818-0300              │
├──────────────────────────────────────────────────────────────────────────┤

  host       server-b
  unraid     7.3.1  (kernel 6.6.x)
  cpu / ram  <cpu model>  ·  128 GB
  board      <board>
  uptime     42.3 days

▶ Preflight
──────────────────────────────────────────────────────────────
  ✓ root
  ✓ core deps present
  ✓ sources present
  ✓ dest writable
  ✓ no other backup running
  ✓ immich containers detected: immich-server immich-machine-learning …
  · space:  need ~433G  ·  free 8.2T on /mnt/user/data/backup_immich

▶ Stopping Immich stack
  ✓ stopped immich-server
  ✓ stopped immich-machine-learning
  ✓ stopped immich-postgres
  ✓ stopped immich-redis

▶ Appdata: /mnt/user/appdata_immich → …/appdata.tar.gz
  ✓ appdata archived

▶ Photos: /mnt/user/immich/immich/photos → …/photos/
  [rsync --info=progress2 output here]
  ✓ photos synced

▶ Restarting Immich stack
  ✓ started immich-*

▶ Retention: keep 7d / 4w / 6m
  · pruned 20260710-0300
  ✓ nothing else to prune

╰──────────────────────────────────────────────────────────────────────────╯
```

Cron / User Scripts runs get the same content in `--quiet` mode: no boxes, `WARN`/`ERROR`/`OK` prefixed lines, one line per phase.

## Exit codes

| Code | Meaning | Stack state |
|---|---|---|
| `0`   | Clean run                          | up |
| `1`   | Preflight failed                   | untouched |
| `2`   | Backup failed mid-run              | up (trap restarted it) |
| `3`   | **Stack restart failed** ⚠️        | possibly down — investigate now |
| `4`   | `--verify` or `--restore` failed   | untouched |
| `130` | Interrupted (Ctrl-C)               | up (trap restarted it) |

## User Scripts scheduling

Save `script.sh` as the User Scripts script body (User Scripts renames it to `script` with no extension when you save). Two useful patterns:

**A. Full automated backup — daily, quiet mode for the log pane.** A daily run keeps the GFS retention window meaningful. First run is slow (initial photo rsync); every subsequent run is fast because rsync is incremental.

```bash
bash /boot/config/plugins/user.scripts/scripts/immich-backup/script --quiet
```

Schedule: `0 3 * * *` (daily at 3am).

**B. Reminder only — you run the backup by hand.** Useful if you'd rather not have long-running tar+rsync on an autopilot. Uses `--remind`, which fires an Unraid notification with the last backup's age and the command to run — **no backup work**, so schedule it as often as you like.

```bash
bash /boot/config/plugins/user.scripts/scripts/immich-backup/script --remind
```

Schedule: `0 9 1 * *` (9am on the 1st of each month) for a monthly nudge — the icon escalates to `warning` when the last backup is 30+ days old.

## Known limitations (v0.1.0)

- **`--restore` is stubbed.** It refuses to run, on purpose. The restore path will land in v0.2 once `--run` has one green live-target run behind it and the failure modes are understood; running a restore before that would be trusting a backup that hasn't been proven yet.
- **No encryption.** The archive is plaintext. If `--dest` is a share that leaves the box, encrypt at the destination layer (rclone crypt, LUKS on the target disk).
- **No offsite step.** Deliberately out of scope; run `rclone sync` against `--dest` from a separate User Scripts entry if you want 3-2-1.
- **Compose dir default assumes compose.manager plugin.** If you deploy Immich a different way, pass `--compose-dir`.
- **`--skip-stop` is unsafe.** It exists for testing only; postgres data files copied while the DB is running are not consistent.

## Verified live (Unraid 7.3.1)

First live climb, 2026-08-18:

- **Rung 3 — `--preflight-only`:** all checks green; containers correctly discovered as `immich_server` / `immich_machine_learning` / `immich_postgres` / `immich_redis` (grep matches underscore names as well as dashed).
- **Rung 4 — smallest live scope** (`--skip-photos`, aggressive retention): 4/4 containers stopped, ~1 GB appdata tarball written, compose copied, 4/4 containers restarted, manifest sha256 verified.
- **Rung 5 — full backup:** 425 GB rsync of 129,627 photo files in 1h 30m at ~80 MB/s, all phases green, both `--verify` and `--list` clean.

The trap-based stack restart is proven live on this hardware. Ongoing `--preflight-only` remains the recommended health check after any target-OS upgrade.

## License

MIT — see [../LICENSE](../LICENSE).
