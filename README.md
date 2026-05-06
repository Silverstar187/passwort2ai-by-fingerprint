# Passwort2AI by Fingerprint

<p align="center">
  <img src="docs/touchid-dialog.png" alt="Touch-ID dialog: Passwort2AI is trying to Fetch &quot;Google Cloud API Token&quot;" width="380">
</p>

## Why

AI agents need passwords. Pasting them in chat leaks them everywhere.

> **Agent needs PW → allow by Touch-ID → done.**

No paste. No chat-leak. The secret goes straight to where it's needed.

```bash
p2ai fetch "Google Cloud API Token"
# 👆 Touch-ID → clipboard → auto-clears in 30s
```

## How

ssh-agent for KeePass, gated by Touch-ID. Wraps `keepassxc-cli`. Master password lives only in the macOS Keychain (released via `LAContext`). An optional in-RAM agent caches secrets so repeat fetches skip the prompt.

- **Read** — `fetch`, `list`, `otp`, `attachment`, `gtoken`
- **Write** — `add`, `edit`, `rm`, `mv`
- **Session** — `unlock` / `status` / `lock`

## What it isn't

- Not a replacement for KeePass — your `.kdbx` is the source of truth.
- Not new crypto — decryption is `keepassxc-cli`.
- Not host hardening — if the machine is compromised, this doesn't save you. See [Caveats](#caveats).

> **macOS only.** Built on Touch-ID + Keychain + `LAContext`.

## Install

```bash
brew install silverstar187/p2ai/passwort2ai
p2ai setup
```

That's it. `p2ai setup` enrolls your master into the macOS Keychain and picks your `.kdbx` via a native file dialog.

<details>
<summary>Install from source instead</summary>

```bash
git clone --branch v0.4.0 --depth 1 https://github.com/Silverstar187/passwort2ai-by-fingerprint.git ~/.passwort2ai
~/.passwort2ai/install.sh
p2ai setup
```

`--branch v0.4.0` pins to a reviewable commit SHA. `install.sh` compiles the Swift binaries and links `p2ai` into `~/.local/bin`.
</details>

## Daily use

Two egress paths only — both ephemeral, neither hits stdout or disk:
**`pbcopy` (default)** for human-driven paste, **`--export VAR` + `eval`** for tools that read from env.

```bash
# Read
p2ai fetch "<entry>"                              # → clipboard, auto-clear 30s
p2ai fetch "<entry>" --attr UserName              # any attribute (default: Password)
eval "$(p2ai fetch '<entry>' --export TOKEN)"     # → $TOKEN env-var
p2ai list [query]                                 # metadata-only search
p2ai otp "<entry>"                                # current TOTP code
p2ai attachment "<entry>" file.json -o out.json   # binary attachment → file

# Write
p2ai add "<entry>" -u USER                        # auto-generates 24-char password
p2ai edit "<entry>" -g                            # rotate password
p2ai rm "<entry>" [-f]                            # delete
p2ai mv "<entry>" "Group/Subgroup"                # move

# Session cache (Touch-ID once, fetch many)
p2ai unlock                                       # 5min idle, 30min hard cap
p2ai unlock --mode per-entry                      # master never cached
p2ai status / p2ai lock
```

> `--print` (stdout dump) and `-o FILE` for `fetch` are intentionally absent. Stdout dumps land in AI-agent transcripts; disk writes leave artefacts. The wrapper refuses both. Upgrading from 0.3.x? See [CHANGELOG.md](CHANGELOG.md#040--2026-05-06).

## Requirements

- macOS with Touch-ID enrolled (`bioutil -c` shows ≥1 template)
- `keepassxc-cli` (auto-detected from KeePassXC.app, Homebrew, or `~/bin`)

## Security

Master password lives in macOS Keychain. Every `fetch` triggers `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` → Touch-ID dialog. The KeePass DB stays encrypted on disk. The master is held in shell-variable scope for one `keepassxc-cli` call, then cleared.

`p2ai unlock` spawns a short-lived agent (`p2ai-agent`) that caches secrets in process RAM with idle TTL + 30-min hard cap. The agent listens on a Unix socket (mode 600 in a mode-700 dir) and verifies peer UID via `getpeereid()`. Auto-locks on `com.apple.screenIsLocked`, `com.apple.screensaver.didstart`, idle expiry, hard cap, or `p2ai lock`. `rm` / `edit` / `mv` invalidate cached entries so rotations don't linger.

Two modes:
- `session` (default) — master + per-entry values cached. One Touch-ID at unlock; every subsequent fetch is instant. Threat model = `ssh-agent` / `sudo` cache.
- `per-entry` — master is never cached. New entries need a fresh Touch-ID; fetched entries are cached until idle expiry.

## Caveats

Passwort2AI is a **UX layer for LLM-driven workflows**. It removes the "paste your token in chat" anti-pattern. It does **not** harden your machine or your secret store.

<details>
<summary>What it does <strong>not</strong> protect against</summary>

It only helps when:

1. **The LLM agent respects the skill rules** — fetches via `p2ai`, never echoes values back, uses `--export` + `eval` for env-vars. A jailbroken agent can still leak.
2. **Your host is not compromised** — RAM-scraping malware, rogue browser extensions, or `pbpaste` from another process all bypass this layer.
3. **The user follows the flow** — `p2ai unlock` on public WiFi without `p2ai lock` afterwards leaves a RAM window.

**Out of scope:** compromised laptop, unattended unlocked screen, malicious browser extensions, memory-scraping malware, physical attacks, phishing pages, unencrypted `.kdbx` backups in iCloud, a coerced or buggy LLM that pastes the secret anyway.

**In scope:** "Claude needs the Cloudflare token" → fetched silently, lands in env, never crosses chat. Pasting tokens into Slack / GitHub issues / screen-shares → friction makes you not do it. Convenience-driven shortcuts that historically led to credentials in `~/.zsh_history`.

For threats #2 / #3 you need a hardware token (YubiKey + KeePassXC Yubikey challenge-response), full-disk encryption with a separate key, and host protection. Passwort2AI is orthogonal — it's the layer between your KeePass DB and the AI tools you actually use day-to-day.
</details>

## License

MIT — see [LICENSE](LICENSE).
