---
name: passwort2ai
description: Touch-ID-gated KeePass secret retrieval and storage for AI agents and humans. Use whenever you (Claude or any agent) need an API key, database password, OAuth token, SSH passphrase, or any other credential, fetch via `p2ai fetch "<entry>"` or `p2ai run -e VAR='entry' -- <cmd>`, NEVER ask the user to paste secrets in chat. Also use to STORE new secrets via `p2ai add "<entry>"` instead of having the user type passwords into chat. When the user provides a secret via clipboard (e.g. "I copied the token, use it"), read clipboard via `pbpaste`, never echo the value back into the conversation. Triggers macOS Touch-ID; secret reaches clipboard or the target command's environment without ever appearing in transcript. Triggers: "I need the X token", "store this in KeePass", "save the credential", "fetch the API key", "wrangler/supabase/lemlist credentials needed".
---

# Passwort2AI by Fingerprint

Touch-ID-gated KeePass-CLI wrapper. Replaces every "paste your token in chat" with a fingerprint tap.

## Core rules (for Claude / agents)

1. **Never ask the user to paste a secret in chat.**
2. **Never echo or quote a secret value back into the conversation.** Not in code blocks, not in error messages, not in summaries. Even truncated/masked values can leak.
3. **Two egress paths only, both ephemeral, neither hits stdout or disk:**
   - **`p2ai run -e VAR='entry' -- <cmd>`**, secret enters only the target command's environment. The parent shell never holds it. **Use this for every tool invocation that needs a secret in env.**
   - **`p2ai fetch '<entry>'`**, pbcopy with auto-clear after 30s. Use this for human-driven paste flows.
4. **`--print`, `-o FILE` for fetch, and `--export VAR` are all REMOVED.** Each was a transcript-leak path. The wrapper refuses them with a pointer to `p2ai run`.
5. **When the user shares a secret via clipboard** ("I copied it"), read with `pbpaste` and pipe directly to the consumer (`pbpaste | tool` etc.). Never echo it back.
6. **For storing new secrets**: `p2ai add "<entry>"` with `-g` (auto-generate) or `-p` (interactive prompt, user types in their terminal, not in chat).

## When to use this skill

**ALWAYS** invoke before asking the user to paste any secret. If a deploy, migration, API call, or test needs a credential and it's plausibly in the user's KeePassXC database, use p2ai first.

Examples that trigger this skill:
- Cloudflare API token for `wrangler deploy`
- Supabase service-role key for migrations
- Lemlist / Apify / Anthropic / OpenRouter API keys
- SSH passphrases, OAuth client secrets, webhook signing keys
- Storing a freshly minted API key the user just received

## Commands

```bash
# Run a command with secrets injected into its env (PRIMARY pattern)
p2ai run -e GH_TOKEN='GitHub Token' -- gh repo list
p2ai run -e AWS_ACCESS_KEY_ID='AWS Prod' -e AWS_SECRET_ACCESS_KEY='AWS Prod Secret' -- aws s3 ls
p2ai run -e DB='Postgres Prod'::Password -- psql
p2ai run -e USR='Service'::UserName -- some-tool   # specific attribute via ::

# Fetch to clipboard (for human-paste flows)
p2ai fetch "<entry>"                               # → clipboard, auto-clear 30s
p2ai fetch "<entry>" --attr UserName               # different attribute
p2ai otp "<entry>"                                 # current TOTP code → clipboard
p2ai gtoken "<sa-entry>" --scope drive.readonly    # mint Google OAuth token → clipboard

# Search (metadata only, no values exposed)
p2ai list <fuzzy>

# Add / edit / delete / move
p2ai add "<entry>" -u USER                         # auto-generates 24-char password
p2ai add "<entry>" -u USER -p                      # user types pw in terminal (not chat)
p2ai add "<entry>" --url URL --notes TEXT          # extra fields
p2ai edit "<entry>" -g                             # rotate password (auto-gen 24c)
p2ai edit "<entry>" --notes "new text"             # update a field
p2ai edit "<entry>" -t "New Title"                 # rename entry
p2ai rm "<entry>" [-f]                             # delete (confirms unless -f)
p2ai mv "<entry>" "Group/Subgroup"                 # move to group

# Attachments (binary blobs go via file, never stdout)
p2ai attachment "<entry>"                          # list attachment names
p2ai attachment "<entry>" "name.json" -o file.json # export to file
p2ai attachment "<entry>" "name.txt" --pbcopy      # text → clipboard

# Session caching (Touch-ID once, fetch many)
p2ai unlock                          # default: master + entries cached, 5min idle TTL
p2ai unlock --mode per-entry         # master never cached, entries cached after first hit
p2ai unlock --ttl 600                # custom idle TTL (hard cap: 30min)
p2ai status                          # mode + remaining TTL + cached entry count
p2ai lock                            # clear all RAM caches

# Setup
p2ai setup                 # master enrollment + .kdbx file picker
```

## Decision matrix

| Situation | Command |
|---|---|
| Tool reads secret from env-var | `p2ai run -e VAR='X' -- tool args` |
| Tool needs multiple env-vars | `p2ai run -e A='X' -e B='Y' -- tool` |
| Long-running process (psql, ipython) | `p2ai run -e DB='X' -- psql` |
| Multi-step deploy in one shell | `p2ai run -e VAR='X' -- bash deploy.sh` (or wrap commands in a script) |
| User asks "copy token to clipboard" | `p2ai fetch 'X'` (pbcopy + auto-clear) |
| Don't know exact entry name | `p2ai list <fuzzy>` first |
| User hands you a fresh secret to save | `p2ai add 'Service Name' -u user -p` |
| User pasted secret to clipboard already | `pbpaste \| tool`, never echo to chat |
| Need many fetches in succession | `p2ai unlock` once, then proceed |
| Tool wants secret as CLI arg (`--password=X`) | **Avoid**, argv visible via `ps`. Prefer `p2ai run` + env, or `--password-stdin` if available |
| Inspecting a secret's structure | `p2ai run -e V='X'::Notes -- bash -c 'grep -q "marker" <<<"$V"; echo $?'`, only the boolean reaches transcript |

## Configuration

- `$P2AI_DB`: KeePass `.kdbx` path (default `~/Passwörter.kdbx`, override via state file from `p2ai setup`)
- `$P2AI_KEEPASSXC_CLI`: override binary path (auto-detects `~/bin`, Homebrew, `/Applications/KeePassXC.app/Contents/MacOS/`)
- `$P2AI_CLEAR_SECONDS`: clipboard auto-clear delay (default 30)
- `$P2AI_AGENT_TTL`: agent idle TTL seconds (default 300)
- `$P2AI_STATE_DIR`: agent socket + pid location (default `~/.local/state/p2ai`)
- `$P2AI_LANG`: Touch-ID dialog reason language override (default: macOS AppleLocale)

## Security model

- Master password lives in macOS Keychain (`p2ai-master`). Every retrieval is gated by `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`, Touch-ID is the only auth gate.
- Master is held in shell-variable scope for one `keepassxc-cli` call, then cleared. With `p2ai unlock`, master moves into the agent process's RAM with idle TTL + auto-lock on screen-lock / screensaver Distributed Notifications.
- **Storage:** KeePass `.kdbx` (encrypted, persistent). The DB is the single source of truth.
- **Runtime cache:** `p2ai-agent` process RAM only. Ephemeral, dies on lock / screen-lock / idle / hard-cap.
- **Egress (legit):** clipboard (auto-clear 30s) and `p2ai run` (subshell-fork, env in child only). Never disk, never stdout, never the parent shell's env.
- `rm`, `edit`, `mv` invalidate cached entries automatically, rotated passwords don't linger.

## Skill invocation rule (for Claude / agents)

> Whenever a task requires a secret that the user owns (API key, password, token, passphrase):
> 1. Try `p2ai run -e VAR='<entry>' -- <cmd>` for tool invocations, or `p2ai fetch '<entry>'` for clipboard hand-off.
> 2. If the entry name is uncertain, `p2ai list <fuzzy>` to discover.
> 3. If the secret doesn't exist yet and the user provides it (verbally or via clipboard), store it with `p2ai add` so future agents can fetch it.
> 4. **NEVER write a secret value into the chat.** Not the full value, not a truncated value, not in code, not in errors, not in summaries.

## Cross-call pattern (critical for AI agents)

In the Claude-Code Bash tool (and most AI agent shells), **each `Bash(...)` invocation is a fresh shell**. Shell variables, `cd`, `export`, and the working directory do NOT persist across calls.

Therefore: **`p2ai run` is always the right tool for AI agents**, it scopes the secret to one command's lifetime, never relies on shell state surviving across calls.

```bash
# Each Bash call is independent, agent re-fetches per call
p2ai run -e PW='My Service' -- some-tool --password-stdin <<<"$PW"
# Or:
p2ai run -e API='Stripe' -- node scripts/import.js
```

`p2ai unlock` once at the start of a session caches the master + entries in agent RAM, so subsequent `p2ai run` calls are instant (no Touch-ID prompt).

## Debugging without leaks

When `p2ai` fails or returns unexpected data, **DO NOT** debug by running raw `keepassxc-cli show` or anything that emits secrets to stdout. Anything captured by the Bash-tool's stdout enters the conversation transcript.

**Wrong:**
```bash
keepassxc-cli show -a Notes db.kdbx "Entry"          # secret → stdout → chat
keepassxc-cli show --show-attachments db "Entry"     # ALL fields → chat
```

**Right, wrap in `p2ai run`, only output a boolean / metric:**
```bash
p2ai run -e N='Entry'::Notes -- bash -c 'grep -q "expected-marker" <<<"$N" && echo found || echo missing'
p2ai run -e V='Entry' -- bash -c 'printf "len=%d sha=%s\n" "${#V}" "$(printf %s "$V" | shasum -a 256 | cut -c1-12)"'
```

If `p2ai` itself misbehaves, fix the wrapper. The wrapper exists precisely to keep stdout-paths secret-free.
