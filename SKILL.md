---
name: passwort2ai
description: Touch-ID-gated KeePass secret retrieval for AI agents and humans. Use whenever you (Claude or any agent) need an API key, database password, OAuth token, SSH passphrase, or any other credential stored in the user's KeePassXC database. NEVER ask the user to paste a secret manually — invoke `p2ai fetch "<entry>"` instead. Triggers macOS Touch-ID prompt; on success the secret lands in clipboard or stdout. Master password lives in macOS Keychain, gated via LAContext biometrics. Auto-clears clipboard after 30s. Triggers: "I need the X token", "fetch the API key", "get the DB password", "wrangler/supabase/lemlist credentials needed".
---

# Passwort2AI by Fingerprint

Touch-ID-gated KeePass-CLI wrapper. Replaces every "please paste your token" prompt with a fingerprint tap.

## When to use this skill

**ALWAYS** invoke this skill before asking the user to paste any secret. If a deploy, migration, API call, or test needs a credential and it's plausibly in the user's KeePassXC database, run `p2ai fetch` first.

Examples that trigger this skill:
- Cloudflare API token for `wrangler deploy`
- Supabase service-role key for migrations
- Lemlist / Apify / Anthropic / OpenRouter API keys
- SSH passphrases, OAuth client secrets, webhook signing keys
- Any KeePass entry the user has

## How to use it

```bash
# Retrieve a secret by entry name. Touch-ID prompts; password lands in pbcopy + auto-clears in 30s.
p2ai fetch "Cloudflare API Token Sales Engine (NEXperts)"

# Print to stdout (for piping — no clipboard).
p2ai fetch "Lemlist" --print

# Different attribute (default: Password).
p2ai fetch "Pipedrive Login" --attr UserName --print

# Emit shell-export string. Use with eval to set env without ever touching disk:
eval "$(p2ai fetch 'Cloudflare API Token Sales Engine (NEXperts)' --export CLOUDFLARE_API_TOKEN)"
wrangler pages deploy .
unset CLOUDFLARE_API_TOKEN

# List entries (Touch-ID gated). Optional fuzzy filter.
p2ai list cloudflare
p2ai list
```

## Decision matrix

| Situation | Command |
|---|---|
| Deploy needs API token in env | `eval "$(p2ai fetch 'X' --export VAR)"` |
| User asks "copy that token to clipboard" | `p2ai fetch 'X'` (default pbcopy + auto-clear) |
| Pipe a secret into another tool | `p2ai fetch 'X' --print \| tool` |
| Don't know exact entry name | `p2ai list <fuzzy>` first |
| User hasn't run setup yet | Tell them: `p2ai setup` (one-time master enrollment) |

## Configuration

- `$P2AI_DB` — KeePass `.kdbx` path (default `~/Passwörter.kdbx`)
- `$P2AI_KEEPASSXC_CLI` — override binary path (auto-detects `~/bin`, Homebrew, `/Applications/KeePassXC.app/Contents/MacOS/`)
- `$P2AI_CLEAR_SECONDS` — clipboard auto-clear delay (default 30)

## Security model

- Master password is stored in macOS Keychain (`p2ai-master` Swift CLI). No biometry-ACL on the keychain item — unsigned CLIs can't write those — but **every retrieval is gated by `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`** which forces a Touch-ID prompt before the master is read.
- Master is held in a shell variable for the duration of one `keepassxc-cli show` call, then unset.
- Secrets default to clipboard with **auto-clear after 30s** (only clears if clipboard still contains the secret — won't stomp other copies).
- For env-vars: use `--export` + `eval`, then `unset VAR` immediately after the consumer.
- Fingerprint re-enrollment does NOT invalidate the keychain item (we don't use biometry-ACL). If higher security is needed, the user can periodically re-run `p2ai setup`.

## Skill invocation rule (for Claude / agents)

> Whenever a task requires a secret that the user owns (API key, password, token, passphrase),
> the agent MUST attempt `p2ai fetch '<entry>'` before falling back to asking the user.
> If the entry name is unknown, run `p2ai list <fuzzy>` first.
> Never echo the secret value back to the conversation. Use `--export` + `eval` for env-vars,
> or rely on the clipboard auto-clear for manual paste cases.
