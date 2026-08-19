# immich-backup — Project Context

Immich backup for Unraid: stop-stack → rsync photos + tar appdata + copy compose →
restart stack → GFS rotate. Single bash file, drops into User Scripts. Sibling to
[`../DeepScanScriptClaude`](../DeepScanScriptClaude) and
[`../hardware-stress-test`](../hardware-stress-test) in the same repo.

Current version: **v0.1.4** · **first live run on server-b 2026-08-18** (rung 5 climbed: 425 GB
rsync + trap-based stack restart both verified live). See [HANDOFF.md](HANDOFF.md) for current
state and roadmap.

## Files

| File | Role |
|---|---|
| `script.sh` | The bash entry-point (single file, all logic inlined) |
| `README.md` | Front door: quickstart, staged first-run, phases, exit codes, TUI mockup |
| `CHANGELOG.md` | Per-tool version history |
| `HANDOFF.md` | Conversation handoff — current state, next steps |
| `CLAUDE.md` | This file |
| `diag/` | Local-only workspace for the server-b diag zip used during design (gitignored — not committed) |

## Hard constraints — never violate

1. **Stack always restarts.** The EXIT/INT/TERM trap that calls `start_stack`
   is the single most important line of code in this tool. Never move stack
   operations into a subshell or backgrounded task; never remove the trap;
   never change `STACK_WAS_STOPPED=1` to be set anywhere except right after a
   successful `docker stop`. Exit code `3` is reserved for "trap ran and
   restart still failed."

2. **`set -u` and `set -o pipefail` ON. `set -e` intentionally OFF.**
   A phase must be able to fail without killing the cleanup trap that restarts
   the stack. Every phase function returns its own rc; the caller decides.

3. **Self-contained.** Only tools that ship with Unraid base + docker:
   `docker`, `rsync`, `tar`, `sha256sum`, `awk`, `sed`, `tr`, `date`, `hostname`,
   `id`, `df`, `du`, `find`, `cat`, `head`, `sort`, `stat`, `mkdir`, `mv`, `cp`,
   `touch`, `rm`, `chmod`. No package installs, no `jq`, no Nerd Tools.

4. **Writes only to `--dest` and `/var/lock`.** No writes to shares, no writes
   outside the backup root or the lockfile. Verify:
   ```bash
   grep -nE '\b(rm|mv|cp|tar|rsync)\b' script.sh
   ```
   Every `rm` must target `$DEST_ROOT`, `$DEST_TMP`, `$LOCKFILE`, or the
   `.write-test-$$` probe file. Every `rsync`/`tar`/`cp -a` destination must
   live under `$DEST_TMP` or `$DEST_ROOT`.

5. **Single bash file.** All logic inlines as functions.

6. **Cross-platform honesty.** Dev box is Windows; target is Unraid 7.3.1
   (bash 5.x, coreutils GNU, busybox absent for the paths we touch). Anything
   that reads `/proc`, calls `docker`, or does `date -d` arithmetic is
   **unverified until rung 3** (`--preflight-only` on server-b). Keep the "never
   yet verified" list in the README honest.

## Safety / verification — run after every edit

On the Windows dev box, use the bash bundled with Git for Windows (bash 5.x) —
`<git-install>\bin\bash.exe`.

```bash
bash -n script.sh                              # syntax
grep -nE '\b(rm|mv|dd)\b' script.sh            # audit every destructive op
bash script.sh --help                          # help text
bash script.sh --dry-run --dest ./tmp-out      # every action, no side effects
```

Runtime tests live in the scratchpad (not committed): trap-fires-on-SIGINT,
preflight-fail-aborts-clean, retention-prune-math, verify-detects-corrupt-tar.
Pattern: source functions into a subshell with `bash -c 'source script.sh …'`
after commenting out `main "$@"`, then mock `docker` / `rsync` with shell
functions that log arguments to a file.

## Coding preferences

- Minimal, focused changes. No comments explaining WHAT — only WHY if non-obvious.
- The TUI uses fixed-width boxes; `_pad` is byte-length based, so any coloured
  or unicode content needs a plain-ASCII stencil string for width math (same
  rule as hardware-stress-test).
- Keep `README.md`, `CHANGELOG.md`, `HANDOFF.md`, `CLAUDE.md`, and the root
  README in sync on every change.

## Key internals

- `parse_args` — hand-rolled flag loop; every flag has a long form; unknown
  flag aborts with usage.
- `demo_collect` / `demo_report` — server-identity block; safe set only
  (host, machine-id, unraid version, kernel, cpu, ram, board, uptime).
  Feeds both the TUI and `manifest.json`. Same pattern as
  [`../hardware-stress-test`](../hardware-stress-test).
- `preflight` — root → deps → paths → dest → lockfile → containers → space.
  Runs standalone under `--preflight-only`; runs again under `--run` before
  anything is touched.
- `discover_containers` — `docker ps --format '{{.Names}}' | grep -iE '^immich'`.
  Case-insensitive; picks up `immich-*` and `Immich*` variants.
- `stop_stack` / `start_stack` — `STACK_WAS_STOPPED` gates the restart in
  both the happy path and the trap. `STACK_WAS_STOPPED=1` is set BEFORE the
  first `docker stop` runs, so a partial stop still triggers a restart of
  the ones that did stop.
- `backup_appdata` / `backup_photos` / `backup_compose` — each is a self-contained
  phase; each honours `MODE=dry` internally so `--dry-run` never touches disk.
  Order is appdata → compose → photos (smallest & safest first; photos are
  the largest and most likely to fill the destination).
- `write_manifest` — printf-composed JSON, no `jq`. Includes sha256 of the
  appdata tarball only (photos are the source of truth on the source side
  and are rsync-verified in place; hashing 400G isn't worth it).
- `rotate` — walks `$DEST_ROOT/YYYYMMDD-HHMM`, classifies each into
  dailies/weeklies/monthlies via `date -d`, keeps the last N of each set,
  prunes anything not in the keep union.
- `cleanup_trap` — EXIT/INT/TERM handler. Preserves the original rc, marks
  any partial `$DEST_TMP` as `FAILED`, and calls `start_stack` if
  `STACK_WAS_STOPPED=1`. If the restart fails, exit code is forced to `3`.

## Exit codes

`0` clean · `1` preflight failed · `2` backup failed (stack up) · `3` **stack
restart failed** (stack may be down) · `4` verify/restore failed · `130`
interrupted (stack restarted by trap).

See `HANDOFF.md` for current state and roadmap.
