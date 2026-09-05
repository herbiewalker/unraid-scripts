# nvidia-healthcheck — Project Context

Small Unraid User Script that runs "At Startup of Array" (and on any
schedule the user picks). Checks that `nvidia-smi` is on `PATH` and
returns zero; alerts via `notify` if not. GPU-dependent containers
(Plex hardware-transcode, etc.) commonly break after an Unraid OS
update before the user notices, and this catches it.

Current version: **v0.2.0**.

## Files

| File | Role |
|---|---|
| `script.sh` | The bash entry-point (single file, ~120 lines) |
| `README.md` | Install + usage notes |
| `bootstrap.sh` | Self-updater bootstrap (fetches latest `script.sh` from GitHub on each run) |
| `CLAUDE.md` | This file |

## Brand mark

Silent cron script — a startup banner would only spam the log every time
the job runs. Instead, the `⏣` sigil is baked into the Unraid
notification subject line, so alerts on the phone show the brand mark
without any log noise.

Only touched:
- Constant `BRAND_SIGIL="⏣"` near the top of `script.sh`.
- `alert()` uses `-s "${BRAND_SIGIL} [$HOST] $1"` for the subject.

This is the **canonical pattern** for silent bash tools that want the
brand identity without a banner. Canonical source of the sigil:
`DevPlaybook/templates/brand/brand.sh`.

## Hard constraints

1. **Self-contained** — only tools that ship with Unraid base:
   `nvidia-smi`, `timeout`, `date`, `hostname`, `grep`, `sed`, `curl`
   (for self-update only).
2. **Never blocks** — `nvidia-smi` gets a `timeout 30`. A wedged driver
   is exactly the state this script exists to catch; it must not hang
   the User Scripts runner.
3. **Silent on success** — logs one OK line per run and exits 0. Only
   fires a notification on failure.
