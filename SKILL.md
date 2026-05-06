---
name: passwort2ai
description: Touch-ID-gated KeePass secret retrieval and storage for AI agents and humans. Use whenever you (Claude or any agent) need an API key, database password, OAuth token, SSH passphrase, or any other credential — fetch via `p2ai fetch "<entry>"`, NEVER ask the user to paste secrets in chat. Also use to STORE new secrets via `p2ai add "<entry>"` instead of having the user type passwords into chat. When the user provides a secret via clipboard (e.g. "I copied the token, use it"), read clipboard via `pbpaste`, never echo the value back into the conversation. Triggers macOS Touch-ID; secret reaches clipboard, env-var, or pipe without ever appearing in transcript. Triggers: "I need the X token", "store this in KeePass", "save the credential", "fetch the API key", "wrangler/supabase/lemlist credentials needed".
---

# Passwort2AI by Fingerprint

Touch-ID-gated KeePass-CLI wrapper. Replaces every "paste your token in chat" with a fingerprint tap. Adds new entries the same way.

## Core rules (for Claude / agents)

1. **Never ask the user to paste a secret in chat.** Use `p2ai fetch '<entry>'` first.
2. **Never echo or quote a secret value back into the conversation.** Not in code blocks, not in error messages, not in summaries. Even truncated/masked values can leak — keep them out.
3. **When the user shares a secret via clipboard** ("I copied it", "it's in my clipboard"), read it with `pbpaste` and pipe directly to the consumer (`pbpaste | tool` or `eval "$(pbpaste-to-export VAR)"`). Do not echo the clipboard value into chat.
4. **For storing new secrets** the user dictates verbally or wants to save: use `p2ai add "<entry>"` with `-g` (auto-generate) or `-p` (interactive prompt — user types in their terminal, not in chat).
5. **For env-vars** use `--export` + `eval` so the value never lands on disk and never enters chat:
   ```bash
   eval "$(p2ai fetch 'X' --export TOKEN)"
   tool-that-needs-token
   unset TOKEN
   ```

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
# Fetch
p2ai fetch "<entry>"                              # Touch-ID → clipboard → auto-clear 30s
p2ai fetch "<entry>" --print                      # → stdout (for piping)
p2ai fetch "<entry>" --attr UserName --print      # different attribute
eval "$(p2ai fetch '<entry>' --export TOKEN)"     # → $TOKEN env-var, no disk-touch

# Search (Touch-ID gated, no values exposed)
p2ai list <fuzzy>

# Add new entry
p2ai add "<entry>" -u USER                        # auto-generates 24-char password
p2ai add "<entry>" -u USER -g 32                  # custom length
p2ai add "<entry>" -u USER -p                     # user types pw in terminal (not chat)
p2ai add "<entry>" --url URL --notes TEXT         # URL + notes fields

# Session caching (sudo-style — Touch-ID once, fetch many)
p2ai unlock [--ttl 300]    # default 5min idle, 30min hard cap
p2ai status                # show remaining TTL
p2ai lock                  # clear master from RAM

# One-time setup
p2ai setup                 # master enrollment + .kdbx file picker
```

## Decision matrix

| Situation | Command |
|---|---|
| Deploy needs API token in env | `eval "$(p2ai fetch 'X' --export VAR)"` |
| User asks "copy token to clipboard" | `p2ai fetch 'X'` (default pbcopy + auto-clear) |
| Pipe a secret into another tool | `p2ai fetch 'X' --print \| tool` |
| Don't know exact entry name | `p2ai list <fuzzy>` first |
| User hands you a fresh secret to save | `p2ai add 'Service Name' -u user -p` (user types in their terminal) |
| User pasted secret to clipboard already | `pbpaste \| tool` — never echo to chat |
| Multiple fetches in one session | `p2ai unlock` once, then fetch many |
| User hasn't run setup yet | Tell them: `p2ai setup` |

## Configuration

- `$P2AI_DB` — KeePass `.kdbx` path (default `~/Passwörter.kdbx`, override via state file from `p2ai setup`)
- `$P2AI_KEEPASSXC_CLI` — override binary path (auto-detects `~/bin`, Homebrew, `/Applications/KeePassXC.app/Contents/MacOS/`)
- `$P2AI_CLEAR_SECONDS` — clipboard auto-clear delay (default 30)
- `$P2AI_AGENT_TTL` — agent idle TTL seconds (default 300)
- `$P2AI_LANG` — Touch-ID dialog reason language override (default: macOS AppleLocale)

## Security model

- Master password lives in macOS Keychain (`p2ai-master`, native binary with `CFBundleName=Passwort2AI`). Every retrieval is gated by `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` — Touch-ID is the only auth gate.
- Master is held in shell-variable scope for the duration of one `keepassxc-cli` call, then cleared. With `p2ai unlock`, master moves into the agent process's RAM with idle TTL + auto-lock on screen-lock / screensaver Distributed Notifications.
- Secrets default to clipboard with auto-clear after 30s (only clears if clipboard still holds the secret — won't stomp other copies).
- For env-vars: `--export` + `eval`, then `unset VAR`. No disk touch, no chat exposure.

## Skill invocation rule (for Claude / agents)

> Whenever a task requires a secret that the user owns (API key, password, token, passphrase):
> 1. Try `p2ai fetch '<entry>'` first. If the entry name is uncertain, `p2ai list <fuzzy>` to discover.
> 2. If the secret doesn't exist yet and the user provides it (verbally, dictated, or via clipboard), store it with `p2ai add` so future agents can fetch it.
> 3. **NEVER write a secret value into the chat.** Not the full value, not a truncated value, not in code, not in errors, not in summaries.
> 4. If the user copied something to clipboard for you to use, prefer `pbpaste | <consumer>` or `eval "$(pbpaste-style-export VAR)"` and consume it without ever round-tripping through the conversation.
