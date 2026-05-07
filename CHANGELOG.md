# Changelog

All notable changes to Passwort2AI by Fingerprint.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is [SemVer](https://semver.org/), major bumps on breaking CLI changes.

## [0.9.3] - 2026-05-07

### Added

- **`p2ai update [--check] [-y]`** — checks GitHub releases for a newer
  version, prints current vs latest, and prompts `[Y/n]` (setup-style,
  reads from `/dev/tty`) to run the right upgrade command for your install
  method:
  - **brew install** → `brew upgrade silverstar187/p2ai/passwort2ai`
  - **source install** → `git pull --ff-only && ./install.sh`
  - **manual** → prints upgrade hint
  Detects "ahead of latest" (dev build) and skips. `--check` exits 1 if an
  update is available, 0 if up-to-date.
- **`p2ai --version` / `-V`** — print the embedded version.
- Internal `P2AI_VERSION` constant + `P2AI_REPO_API` for release lookups.

### Changed

- `p2ai update` now refers to the version-update command. The legacy
  `update` alias on `p2ai edit` is removed (`p2ai edit` is the canonical
  form for entry edits).

## [0.6.0] - 2026-05-07

### Added

- **`p2ai system-prompt [--target generic|claude|cursor|aider|cline]`** —
  emits AI-agent rules markdown to pipe into `.cursorrules`, `CLAUDE.md`,
  `.aider.conf.yml`, etc.
- **`p2ai install-skill`** — symlinks `SKILL.md` into
  `~/.claude/skills/passwort2ai/SKILL.md` (the directory layout Claude Code
  discovers). Auto-resolves source via `$P2AI_SKILL_MD`, self-symlink
  detection, or brew prefix.
- **`p2ai list --json`** — structured output for programmatic consumption.
- **`p2ai run --env-file FILE`** — load entry mappings from a dotenv-style
  file (`VAR=entry::Attr`).
- **`$P2AI_AUTH_TIMEOUT`** (default 30s) bounds the Touch-ID prompt so a
  forgotten dialog cannot hang indefinitely.
- **Exit-code contract** documented in `bin/p2ai` header
  (0/1/2/3/130 with stable semantics).
- **Guided install** (`install.sh`) — auto-installs `keepassxc-cli` via
  Homebrew when missing, checks Touch-ID enrollment, appends PATH to shell
  rc idempotently, links the Claude Code skill, prints per-project
  one-liners for Cursor/Cline/Aider, and offers to run `p2ai setup`.
- **Guided setup** (`p2ai setup`) — banner explains each step, banner-style
  Swift prompts during master enrollment, auto-creates the KeePass DB at
  `~/passwords.kdbx` when none exists (no file dialog), then runs PATH and
  Claude Code skill checks with `[Y/n]` prompts so setup is self-sufficient
  regardless of install path.

### Changed

- **Default DB path** is now `~/passwords.kdbx` (was `~/Passwörter.kdbx`).
  Existing installs keep their saved path in `~/.local/share/p2ai/db.path`.

### Fixed

- `cmd_setup` smoke-test ran on the original default path instead of the
  user's chosen DB after the file picker. Smoke-test now verifies the
  database that was actually selected/created.
- Installer no longer skips the shell-rc PATH update when `$TARGET` happens
  to be on `$PATH` transiently (which broke new terminals).
- Installer creates the Claude Code skill as a directory link
  (`~/.claude/skills/passwort2ai/SKILL.md`) instead of a flat
  `passwort2ai.md`, which Claude Code does not discover. Migrates legacy
  flat-file installs.
- `cmd_setup` now captures `keepassxc-cli db-create` stderr to a temp file
  and replays it on failure, plus verifies the resulting `.kdbx` is
  non-empty before saving the path.

### Notes

- macOS-only. Built on Touch-ID, Keychain, and `LAContext`.
- Homebrew formula auto-links the Claude Code skill via `post_install`
  when `~/.claude/` exists.

## [0.5.1] - 2026-05-06

### Fixed

- `p2ai run` now uses one-shot env injection plus same-PID `exec`, so
  signals (`SIGINT`, `SIGTERM`) reach the target command directly. Prior
  release wrapped the child in a parent shell that intercepted signals.

## [0.5.0] - 2026-05-06

### BREAKING

- **`--export VAR` removed** from `fetch`, `otp`, `gtoken`, `attachment`. The
  flag printed `export VAR='value'` to stdout, when the caller's stdout was
  captured by an AI-agent's Bash tool (Claude Code, Cursor, etc.), the secret
  string entered the conversation transcript. Even with `eval` consumption,
  any accidental pipe (`| head`, `2>&1 | tee`, command substitution misuse)
  re-exposed the value. Removing it eliminates the foot-gun entirely.

### Migration from 0.4.x

```bash
# Before:
eval "$(p2ai fetch 'GH Token' --export GH_TOKEN)" && gh repo list && unset GH_TOKEN

# After:
p2ai run -e GH_TOKEN='GH Token' -- gh repo list
```

`p2ai run` forks a subshell, exports the var only inside it, and `exec`s the
target command. The parent shell never holds the secret. Multi-secret and
attribute-specific (`entry::UserName`) variants:

```bash
p2ai run \
  -e AWS_ACCESS_KEY_ID='AWS Prod' \
  -e AWS_SECRET_ACCESS_KEY='AWS Prod Secret' \
  -- aws s3 ls
p2ai run -e USER='Service'::UserName -e PW='Service'::Password -- some-tool
```

For multi-step shell sessions: wrap commands in `bash -c "..."` after `--`,
or write a small shell script and run it via `p2ai run -- bash script.sh`.

### Added

- **`p2ai run [-e VAR='entry'[::attr]] [...] -- <command>`**, primary egress
  for tool invocations. Forks a subshell, exports requested secrets there
  only, `exec`s the command. The parent shell's environment never holds the
  values, eliminating the env-leak window between `eval` and `unset` (which
  could be widened by SIGINT, `set -x` traces, or crash dumps).
- 7 new security tests in section 17 verifying the run-isolation contract:
  parent env stays clean, child receives env, multi-secret + ::attr support,
  exit code propagation, secret not in child argv (env-only), no-args case,
  malformed input rejection.

### Changed

- `fetch` no longer accepts `--export`, `--print`, or `-o FILE`. Default
  `pbcopy` is the only egress; `p2ai run` is the recommended path for tools
  that need an env-var.
- `otp` no longer accepts `--export` or `--print`, pbcopy only.
- `attachment` no longer accepts `--export` or `--print`, `-o FILE` (binary
  blobs) and `--pbcopy` (text) are the only paths.
- `gtoken` no longer accepts `--export` or `--print`, pbcopy only.
- `cmd_run` exit codes propagate from the child via standard subshell
  semantics, including SIGINT (130).
- Section 14 of the security suite (peer-UID check) is now an honest SKIP
  with a code-pointer, replacing the weak `strings | grep` test that was
  prone to false positives.

### Documentation

- `SKILL.md` rewritten: `p2ai run` is the primary pattern in the decision
  matrix, with explicit "use `p2ai run` for every tool invocation that needs
  a secret in env" guidance for AI agents.
- README: install pin bumped to v0.5.0; daily-use section leads with `p2ai
  run` examples.

## [0.4.0] - 2026-05-06

### BREAKING

- **`--print` removed** from `fetch`, `otp`, `gtoken`, and `attachment`. Stdout
  dumps land in AI-agent transcripts (Claude Code, Cursor, etc.), that is the
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
- Security test suite at `tests/security.sh`, 28 checks covering filesystem
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

## [0.3.0] - 2026-05-06

### Added

- Full keepassxc-cli command parity:
  - `p2ai rm <entry> [-f]`: delete entry (confirms unless `-f`)
  - `p2ai edit <entry> [-u/--url/--notes/-t/-g/-p]`: update fields, rename, rotate
  - `p2ai mv <entry> <group>`: move between groups
  - `p2ai otp <entry>`: fetch current TOTP code
- Per-entry agent cache mode: `p2ai unlock --mode per-entry` keeps the master
  password out of long-lived RAM. Each *new* entry needs a fresh Touch-ID;
  already-fetched entries are cached until idle expires.
- Screen-lock and screensaver auto-lock subscribers in the agent (already
  present from v0.2 but documented).

## [0.2] - earlier

- Native Swift binaries (`p2ai-master`, `p2ai-agent`) replacing shell-script
  master handling. Strict B-strict agent semantics, locale-aware Touch-ID
  reasons, native DB picker.

## [0.1] - initial

- First release. Bash wrapper around `keepassxc-cli` with Touch-ID gate via
  macOS Keychain + `LAContext`.

