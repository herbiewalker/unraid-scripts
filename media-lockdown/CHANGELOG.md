# Changelog — media-lockdown

All notable changes to this tool. Format is [Keep a Changelog](https://keepachangelog.com/),
version numbers follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.0] — 2026-11-18

### Added
- Initial release. Scans user-picked media folders for executables/scripts/installers,
  setuid/setgid files, special files, and (with `--deep`) EXE/ELF/`#!` content disguised
  as media. Severity: HIGH / MED / REVIEW.
- `fix`: quarantines HIGH findings to `<work-dir>/quarantine/<stamp>/` with a
  `MANIFEST.tsv` (never deletes), strips exec/setuid bits from MED findings.
  `--strict` also quarantines unknown file types. `--restore MANIFEST` undoes a batch.
- Upgrade-safe by design: no write-bit/ownership/directory changes, no `chattr`; every
  `find` carries `-mmin +N` (`--min-age`, default 60) and `fix` re-checks each file's
  age immediately before touching it.
- Interactive TUI: folder browser (`★` marks folders mounted by Plex/Jellyfin/*arr
  containers, `g` jumps between them), scan/fix toggle, deep/strict/min-age toggles,
  skip-list, `w` to save per-server defaults to flash.
- `--discover`, `--docker-audit` (privileged containers, read-write media mounts).
- herbiewalker brand mark, `demo_collect`, GUI→terminal handoff, host-prefixed `⏣`
  notifications, `--self-update` / `--check-update`, sibling `bootstrap.sh`.

### Known gaps
- Never run on live Unraid (see HANDOFF.md "Never yet verified").
