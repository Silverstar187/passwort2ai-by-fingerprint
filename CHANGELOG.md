# Changelog

All notable changes to Passwort2AI by Fingerprint.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is [SemVer](https://semver.org/) — major bumps on breaking CLI changes.

## [0.4.0] — 2026-05-06

### BREAKING

- **`--print` removed** from `fetch`, `otp`, `gtoken`, and `attachment`. Stdout
  dumps land in AI-agent transcripts (Claude Code, Cursor, etc.) — that is the
  exact leak path this tool was built to prevent. The wrapper now refuses
  `--print` with a pointer to the safe alternatives.
- **`-o FILE` removed from `fetch`**. Disk writes leave artefacts requiring
  cleanup. (`-o FILE` is **kept** on `attachment` because attachments are
  typically binary blobs that genuinely need a file path.)

### Migration from 0.3.x

Replace every `--print` usage with one of:

```bash
# Before:
TOKEN=$(p2ai fetch 'X' --print); curl -H "Authorization: Bearer $TOKEN" ...

# After (env-var, value never reaches stdout):
eval "$(p2ai fetch 'X' --export TOKEN)"
curl -H "Authorization: Bearer $TOKEN" ...
unset TOKEN
```

For pure clipboard hand-off, the default (no flag) is `pbcopy` with auto-clear:

```bash
p2ai fetch 'X'           # clipboard, auto-clear after 30s
```

For attachments needing a file path, keep `-o FILE`:

```bash
p2ai attachment 'X' 'cred.json' -o ./cred.json
```

### Added

- `--export VAR` on `otp` and `attachment` (was `fetch`-only before).
- Security test suite at `tests/security.sh` — 28 checks covering filesystem
  permissions, master-password isolation, cache invalidation, idle TTL, lock
  semantics, payload caps, concurrent connections, signal handling, and
  `--print`/`-o FILE` refusal.
- Agent ownership-aware `cleanup()` so a SIGTERM-receiving outgoing agent
  cannot clobber a successor's freshly-written socket and pid file.
- `INVALIDATE <prefix>` agent protocol command. `rm`/`edit`/`mv` now drop
  any cached entries matching the entry prefix so rotated values don't linger.
- `P2AI_STATE_DIR` env var honored by both bash + swift agent (test isolation
  + custom XDG layouts).
- `PUTENTRY` payload hard-cap is now exactly 1 MB (was off by up to one 4 KB
  chunk).
- Signed git tags (`v0.4.0`+) and signed commits (post-d5cc48d) using SSH
  ed25519 + `~/.config/git/allowed_signers`.

### Changed

- `cmd_gtoken` no longer subshells `p2ai fetch --print` to read the SA-JSON
  Notes field. The Notes content is fetched inline via `keepassxc-cli`,
  staying in the bash process's memory; the gcloud key-file tmpfile is mode
  600 in a private 700 tmpdir, shredded on EXIT.
- README restructured: Why → How → What it isn't → Setup. macOS-only callout
  moved below the value pitch.
- Repo install instructions now use `git clone --branch v0.4.0 --depth 1` to
  pin to a reviewable commit SHA.

### Documentation

- `SKILL.md` rewritten around the **two-egress-paths rule** (pbcopy default,
  `--export VAR` for env-var-driven tools).
- New debugging rule: never bypass the wrapper to debug; use env-var capture
  with grep against `$VAR` so only booleans / metrics reach the transcript.

## [0.3.0] — 2026-05-06

### Added

- Full keepassxc-cli command parity:
  - `p2ai rm <entry> [-f]` — delete entry (confirms unless `-f`)
  - `p2ai edit <entry> [-u/--url/--notes/-t/-g/-p]` — update fields, rename, rotate
  - `p2ai mv <entry> <group>` — move between groups
  - `p2ai otp <entry>` — fetch current TOTP code
- Per-entry agent cache mode: `p2ai unlock --mode per-entry` keeps the master
  password out of long-lived RAM. Each *new* entry needs a fresh Touch-ID;
  already-fetched entries are cached until idle expires.
- Screen-lock and screensaver auto-lock subscribers in the agent (already
  present from v0.2 but documented).

## [0.2] — earlier

- Native Swift binaries (`p2ai-master`, `p2ai-agent`) replacing shell-script
  master handling. Strict B-strict agent semantics, locale-aware Touch-ID
  reasons, native DB picker.

## [0.1] — initial

- First release. Bash wrapper around `keepassxc-cli` with Touch-ID gate via
  macOS Keychain + `LAContext`.
