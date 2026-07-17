# hardware-stress-test — Project Context

CPU + RAM stress test for Unraid, built around crash forensics and the hardware's
own error counters rather than a pass/fail score. Runs via the User Scripts plugin,
or directly from a terminal for the interactive setup screen.

Current version: **v0.2.0**

## Files

| File | Role |
|---|---|
| `script.sh` | The bash entry-point (single file, all logic inlined) |
| `README.md` | Full project context, phases, flags, exit codes |
| `HANDOFF.md` | Conversation handoff — current state, next steps |
| `CLAUDE.md` | This file |

## Hard constraints — never violate

1. **Self-contained.** Only tools that ship with Unraid base: `openssl`,
   `sha512sum`, `dd`, `free`, `nproc`, `logger`, `dmesg`, `awk`, `sed`, `tr`,
   `date`, `hostname`, `id`, `df`, `cat`, `head`, `sort`. `stress-ng`, `memtester`,
   `sensors` are used **opportunistically if present** but never required. No
   package installs, no Nerd Tools (deprecated as of 2026).

2. **Single bash file.** All logic inlines as functions.

3. **Writes only to its own scratch + logs.** `/dev/shm/hardware-stress-test/`
   (removed on exit), `/boot/logs/stress-test-*.{log,json}`. Never the array,
   never shares. Verify:
   ```
   grep -nE '\b(rm|mv|dd)\b' script.sh
   ```
   Every `rm` must target `$SHM_ROOT`/`$SHM_DATA`/`$LOCKFILE`; the one `dd` writes
   into `$SHM_DATA` (the RAM pattern seed) only.

4. **`set -u` and `set -o pipefail` ON. `set -e` intentionally OFF** — a phase must
   be able to fail without killing the run, because a partial result is evidence.

5. **The monitor runs in the MAIN process; the load runs in the background.**
   This is the core architecture and the fix for the v0.1 bug (see HANDOFF). Never
   move `monitor_phase` into a background subshell — its `return 1` on an over-temp
   is what actually aborts the run.

## Safety / verification — run after every edit

On a Windows dev box, use the bash bundled with Git for Windows (bash 5.x) —
`<git-install>\bin\bash.exe`.

```
bash -n script.sh                          # syntax
grep -nE '\b(rm|mv|dd)\b' script.sh        # audit every destructive op
```

Runtime tests live in the scratchpad (not committed): thermal-abort path,
RAM-corruption detection, CLI/non-TTY behaviour, TUI alignment + input handling.
Pattern: `eval "$(sed '/^main "$@"$/d' script.sh)"` to source functions without
running `main`, then mock `cpu_temp`/capabilities. Note: `cpu_temp` is called via
`$(...)` (subshell), so any mock must persist through a file, not a shell variable.

## Coding preferences

- Minimal, focused changes. No comments explaining WHAT — only WHY if non-obvious.
- TUI: padding is computed from a plain-ASCII **stencil** string, never the
  coloured/unicode one (`${#s}` counts bytes). Every stencil must equal the visual
  width of the string it stands in for. `W=67` inner width; variable-length notes
  are `clip`'d to their field budget so a long value can't push the border.
- Keep README.md, HANDOFF.md, CLAUDE.md, and the root README in sync on any change.

## Key internals

- `detect_capabilities` — fills `HAVE_*` flags (hwmon, EDAC, throttle, stress-ng,
  memtester, sensors, root) and array state. Everything downstream is guarded by
  these; nothing is assumed present.
- `cpu_temp` — max across all CPU-name-matched hwmon `temp*_input`, not core 0.
  Falls back to `sensors -u`. Empty if no source → thermal abort disabled (warned).
- `monitor_phase` — main-process control loop; returns 0 (done) / 1 (thermal) /
  2 (hardware error). Sleeps in 1s slices so abort stays responsive.
- `edac_sum` / `mce_count` / `throttle_sum` — read hardware counters; baselined at
  start, delta'd into the summary.
- `ram_verify_loop` — background worker; reports pass/fail/status via files under
  `$STATE` (can't return values across a `&`).
- `tui_run` / `tui_render` / `tui_adjust` — the ANSI setup screen; only entered when
  `[ -t 0 ] && [ -t 1 ]` and `--no-tui` not set.
- `write_summary` — heartbeat log + `summary.json` (printf, no jq). A hardware
  error outranks a clean run for the exit code.

## Exit codes

`0` clean · `1` preflight failed · `2` hardware error · `3` thermal abort · `130` interrupted.

See `HANDOFF.md` for current state and roadmap.
