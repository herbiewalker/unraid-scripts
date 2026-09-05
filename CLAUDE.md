# unraid-scripts — Repo Context

Four self-contained bash tools for Unraid, each in its own subdirectory:

| Tool | Kind | Own CLAUDE.md |
|---|---|---|
| `hardware-stress-test/` | Interactive CPU+RAM burn-in | ✓ |
| `DeepScanScriptClaude/` | Interactive storage-usage scan | ✓ |
| `immich-backup/` | Interactive stop-stack backup | ✓ |
| `nvidia-healthcheck/` | Silent cron GPU check | — |

Each tool ships as a single `script.sh` (or `script`) file. See each
tool's `CLAUDE.md` for its own constraints. See [`README.md`](README.md)
for the front door and [`HANDOFF.md`](HANDOFF.md) for cross-tool state.

## Brand mark — herbiewalker

Every tool in this repo carries the herbiewalker code brand:

- **Interactive tools** (3): inline `brand_banner_modern` block near the
  startup path; called at the top of `main()` or right above the tool's
  existing `print_banner_modern`. Prints to a TTY, no-ops in User
  Scripts / cron.
- **Silent tools** (nvidia-healthcheck): no banner (would spam the log).
  Just `BRAND_SIGIL="⏣"` defined near the top, prefixed onto the Unraid
  notification subject.

**Canonical source**: `DevPlaybook/templates/brand/brand.sh` — the block
inlined into each tool is a self-contained copy. If the canonical brand
ever changes (new colour, new sigil, new banner shape), update the
canonical source first, then re-sync all four tools here in one commit.

Grep for the inlined block:

```bash
grep -l "BRAND_SIGIL" */script* 2>/dev/null
```

## Cross-repo conventions

- **Single-file constraint** everywhere — no sourceable libraries. Any
  helper (self-updater, brand mark, notification wrapper) is inlined per
  tool.
- **Self-updater** (`--self-update` / `--check-update`) and sibling
  `bootstrap.sh` — see each tool's block near the top.
- **Server demographics** — `demo_collect` fills `DEMO_*` from `/proc`
  and `/sys`; feeds both the tool's `print_banner_modern` and its
  `summary.json`. Same shape in every tool.
- **Host-prefixed notifications** — `notify_unraid` subject is
  `⏣ [<host>] <subject>` (⏣ = brand sigil).

## Live vs. dev

Dev box is Windows (Git-Bash 5.x). Target is Unraid 7.3.x. Anything
that reads `/proc`, calls `notify`, or depends on GNU coreutils
behaviour is **unverified until a real live-hardware run.** Keep the
"never yet verified" lists honest in each tool's HANDOFF.md.
