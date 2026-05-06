---
name: passwort2ai
description: Touch-ID-gated KeePass secret retrieval and storage for AI agents and humans. Use whenever you (Claude or any agent) need an API key, database password, OAuth token, SSH passphrase, or any other credential — fetch via `p2ai fetch "<entry>"`, NEVER ask the user to paste secrets in chat. Also use to STORE new secrets via `p2ai add "<entry>"` instead of having the user type passwords into chat. When the user provides a secret via clipboard (e.g. "I copied the token, use it"), read clipboard via `pbpaste`, never echo the value back into the conversation. Triggers macOS Touch-ID; secret reaches clipboard or env-var without ever appearing in transcript. Triggers: "I need the X token", "store this in KeePass", "save the credential", "fetch the API key", "wrangler/supabase/lemlist credentials needed".
---

# Passwort2AI by Fingerprint

Touch-ID-gated KeePass-CLI wrapper. Replaces every "paste your token in chat" with a fingerprint tap.

## Core rules (for Claude / agents)

1. **Never ask the user to paste a secret in chat.** Use `p2ai fetch '<entry>'` first.
2. **Never echo or quote a secret value back into the conversation.** Not in code blocks, not in error messages, not in summaries. Even truncated/masked values can leak.
3. **Two egress paths only — both ephemeral, neither hits stdout or disk:**
   - **`pbcopy` (default)** — clipboard with auto-clear after 30s, for human-driven paste flows.
   - **`--export VAR` + `eval`** — value enters the running shell's environment, never stdout. Use for AI agent flows where a tool reads the secret from env.
4. **`--print` and `-o FILE` for fetch are removed.** Stdout dumps land in transcripts; disk writes leave artefacts. The wrapper refuses both.
5. **When the user shares a secret via clipboard** ("I copied it"), read it with `pbpaste` and pipe directly to the consumer (`pbpaste | tool` or `eval` against the export form). Never echo it back.
6. **For storing new secrets** the user dictates verbally or wants to save: `p2ai add "<entry>"` with `-g` (auto-generate) or `-p` (interactive prompt — user types in their terminal, not in chat).

## When to use this skill

**ALWAYS** invoke before asking the user to paste any secret. If a deploy, migration, API call, or test needs a credential and it's plausibly in the user's KeePassXC database, run `p2ai fetch` first.

Examples that trigger this skill:
- Cloudflare API token for `wrangler deploy`
- Supabase service-role key for migrations
- Lemlist / Apify / Anthropic / OpenRouter API keys
- SSH passphrases, OAuth client secrets, webhook signing keys
- Storing a freshly minted API key the user just received

## Commands

```bash
# Fetch — pbcopy default, --export for env-var tools
p2ai fetch "<entry>"                              # Touch-ID → clipboard → auto-clear 30s
p2ai fetch "<entry>" --attr UserName              # different attribute (default: Password)
eval "$(p2ai fetch '<entry>' --export TOKEN)"     # → $TOKEN env-var, no stdout, no disk

# Search (metadata only, no values exposed)
p2ai list <fuzzy>

# Add new entry
p2ai add "<entry>" -u USER                        # auto-generates 24-char password
p2ai add "<entry>" -u USER -g 32                  # custom length
p2ai add "<entry>" -u USER -p                     # user types pw in terminal (not chat)
p2ai add "<entry>" --url URL --notes TEXT         # URL + notes fields

# Edit / rename / delete / move
p2ai edit "<entry>" -g                            # rotate password (auto-gen 24c)
p2ai edit "<entry>" --notes "new text"            # update a single field
p2ai edit "<entry>" -t "New Title"                # rename entry
p2ai rm "<entry>"                                 # delete (confirms)
p2ai rm "<entry>" -f                              # delete without confirm
p2ai mv "<entry>" "Group/Subgroup"                # move to group

# TOTP / 2FA codes
p2ai otp "<entry>"                                # → pbcopy + auto-clear
eval "$(p2ai otp '<entry>' --export OTP)"         # → $OTP env-var

# Attachments (special: -o FILE legit because attachments are typically files)
p2ai attachment "<entry>"                          # list attachment names (metadata only)
p2ai attachment "<entry>" "name.json" -o file.json # binary blob → file
p2ai attachment "<entry>" "name.txt" --pbcopy      # text → clipboard
eval "$(p2ai attachment '<entry>' 'cfg.json' --export CFG)"  # text → env-var

# Google OAuth access token from Service-Account JSON in entry Notes field
p2ai gtoken "<sa-entry>" --scope drive.readonly    # → pbcopy default
eval "$(p2ai gtoken '<sa-entry>' --scope drive --export TOKEN)"
curl -H "Authorization: Bearer $TOKEN" ...
unset TOKEN

# Session caching (sudo-style — Touch-ID once, fetch many)
p2ai unlock                          # mode=session: master + entries cached, default 5min idle
p2ai unlock --mode per-entry         # master never cached, entries cached after first fetch
p2ai unlock --ttl 600                # custom idle TTL
p2ai status                          # show mode + remaining TTL + cached entry count
p2ai lock                            # clear master + entries from RAM

# One-time setup
p2ai setup                 # master enrollment + .kdbx file picker
```

## Decision matrix

| Situation | Command |
|---|---|
| Tool reads secret from env-var | `eval "$(p2ai fetch 'X' --export VAR)" && tool && unset VAR` |
| User asks "copy token to clipboard" | `p2ai fetch 'X'` (default pbcopy + auto-clear) |
| Don't know exact entry name | `p2ai list <fuzzy>` first |
| User hands you a fresh secret to save | `p2ai add 'Service Name' -u user -p` (user types in their terminal) |
| User pasted secret to clipboard already | `pbpaste \| tool` — never echo to chat |
| Multiple fetches in one session | `p2ai unlock` once, then fetch many |
| Tool wants secret as CLI arg (`--password=X`) | **Don't** — `ps`/`/proc/*/cmdline` exposes argv. Prefer env-var via `--export`, or `--password-stdin` if available. |
| Need to inspect a secret's structure | `eval "$(p2ai fetch X --attr Notes --export N)"; grep -q "marker" <<<"$N"; unset N` — only the boolean reaches transcript |
| User hasn't run setup yet | Tell them: `p2ai setup` |

## Configuration

- `$P2AI_DB` — KeePass `.kdbx` path (default `~/Passwörter.kdbx`, override via state file from `p2ai setup`)
- `$P2AI_KEEPASSXC_CLI` — override binary path (auto-detects `~/bin`, Homebrew, `/Applications/KeePassXC.app/Contents/MacOS/`)
- `$P2AI_CLEAR_SECONDS` — clipboard auto-clear delay (default 30)
- `$P2AI_AGENT_TTL` — agent idle TTL seconds (default 300)
- `$P2AI_STATE_DIR` — agent socket + pid location (default `~/.local/state/p2ai`)
- `$P2AI_LANG` — Touch-ID dialog reason language override (default: macOS AppleLocale)

## Security model

- Master password lives in macOS Keychain (`p2ai-master`, native binary with `CFBundleName=Passwort2AI`). Every retrieval is gated by `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` — Touch-ID is the only auth gate.
- Master is held in shell-variable scope for one `keepassxc-cli` call, then cleared. With `p2ai unlock`, master moves into the agent process's RAM with idle TTL + auto-lock on screen-lock / screensaver Distributed Notifications.
- **Storage:** KeePass `.kdbx` (encrypted, persistent). The DB is the single source of truth.
- **Runtime cache:** `p2ai-agent` process RAM only. Ephemeral, dies on lock / screen-lock / idle / hard-cap.
- **Egress (legit):** clipboard (auto-clear 30s) and `--export VAR` (subprocess RAM, eval-consumed). Never disk, never stdout.
- `rm`, `edit`, `mv` invalidate cached entries automatically — rotated passwords don't linger.

## Skill invocation rule (for Claude / agents)

> Whenever a task requires a secret that the user owns (API key, password, token, passphrase):
> 1. Try `p2ai fetch '<entry>'` first. If the entry name is uncertain, `p2ai list <fuzzy>` to discover.
> 2. If the secret doesn't exist yet and the user provides it (verbally or via clipboard), store it with `p2ai add` so future agents can fetch it.
> 3. **NEVER write a secret value into the chat.** Not the full value, not a truncated value, not in code, not in errors, not in summaries.
> 4. If the user copied something to clipboard for you to use, prefer `pbpaste | <consumer>` and consume it without round-tripping through the conversation.

## Cross-call pattern (critical for AI agents)

In the Claude-Code Bash tool (and most AI agent shells), **each `Bash(...)` invocation is a fresh shell**. Shell variables, `cd`, `export`, and the working directory do NOT persist across calls.

When the same secret is needed in multiple Bash calls (multi-step deploy, several curls):

```bash
# 1. Once: Touch-ID, master cached in agent RAM for 5min idle
p2ai unlock

# 2. Each subsequent Bash call re-fetches via --export.
#    Fast (<1s) because the agent serves the master without re-prompting.
#    The value lives only inside this single Bash invocation.
eval "$(p2ai fetch 'My Service' --export PW)"
some-tool --password-stdin <<<"$PW"
unset PW
```

The secret never sits idle in the clipboard, never reaches stdout, scoped to one Bash invocation. For Google OAuth tokens specifically, `p2ai gtoken --export` mints a fresh token per call — same pattern, no clipboard.

## DEBUGGING RULE (critical — avoid the leak path)

When `p2ai` fails or returns unexpected data, **DO NOT** debug by running raw `keepassxc-cli show` (or any tool that emits secrets) without redirecting stdout. Anything that lands on stdout in a Bash-tool call enters the conversation transcript.

**Wrong:**
```bash
keepassxc-cli show -a Notes db.kdbx "Entry"          # secret → stdout → chat
keepassxc-cli show --show-attachments db "Entry"     # ALL fields → chat
```

**Right — keep value in env-var, only output a boolean / metric:**
```bash
eval "$(p2ai fetch 'X' --attr Notes --export N)"
grep -q "expected-marker" <<<"$N" && echo "found" || echo "missing"
printf 'len=%d sha=%s\n' "${#N}" "$(printf '%s' "$N" | shasum -a 256 | cut -c1-12)"
unset N
```

If `p2ai` itself misbehaves, fix the wrapper rather than bypass it. The wrapper exists precisely to keep stdout-paths secret-free.
