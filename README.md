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

ssh-agent for KeePass, gated by Touch-ID. Wraps `keepassxc-cli`. Master password held only in macOS Keychain (released via `LAContext`). Optional in-RAM agent caches secrets so repeat fetches skip the prompt.

- **Read:** `fetch`, `list`, `otp`, `attachment`, `gtoken`
- **Write:** `add`, `edit`, `rm`, `mv`
- **Session:** `unlock` / `status` / `lock`

## What it isn't

- Not a replacement for KeePass — your `.kdbx` is still the source of truth
- Not new crypto — decryption is `keepassxc-cli`
- Not host hardening — if the machine is compromised, this doesn't save you. See [Caveats](#caveats--what-this-tool-does-not-protect-against)

> **macOS only.** Built on Touch-ID + Keychain + LAContext. Linux/Windows would need a different biometric backend.

## Setup (3 steps)

```bash
# 1. Install — pin to a tagged release, don't follow main blindly.
#    install.sh compiles the Swift binaries locally and symlinks to ~/.local/bin.
#    Read it before running. The whole repo is small enough to audit.
git clone --branch v0.4.0 --depth 1 \
  https://github.com/Silverstar187/passwort2ai-by-fingerprint.git ~/.passwort2ai
( cd ~/.passwort2ai && git verify-tag v0.4.0 2>/dev/null \
    || echo "(unsigned tag — verify via GitHub web UI: commit SHA pinned by tag)" )
~/.passwort2ai/install.sh

# 2. Enroll master password + pick your .kdbx via native file dialog
p2ai setup

# 3. (optional) Cache master in agent for 5min idle to skip Touch-ID per fetch
p2ai unlock
```

> **Why the pin matters.** This tool runs as your user, holds your master password in RAM, and decrypts your KeePass DB. Cloning `main` would trust whatever was pushed last; pinning to `v0.4.0` ties you to a specific commit SHA you can review. Tags are not signed yet (no GPG key) — verify by reading the source before installing.

## Daily use

### Read secrets

Two egress paths only — both ephemeral, neither hits stdout or disk:
**`pbcopy` (default)** for human-driven paste, **`--export VAR` + `eval`** for tools that read from env.

```bash
p2ai fetch "<entry>"                              # Touch-ID → clipboard → auto-clear 30s
p2ai fetch "<entry>" --attr UserName              # any attribute (default: Password)
eval "$(p2ai fetch '<entry>' --export TOKEN)"     # → $TOKEN env-var
tool-that-reads-env-var
unset TOKEN

p2ai list [query]                                 # metadata-only search (no values exposed)
p2ai otp "<entry>"                                # current TOTP code → clipboard
p2ai attachment "<entry>" file.json -o out.json   # binary attachments → file (mode 600)
eval "$(p2ai gtoken '<sa-entry>' -s drive --export TOK)"  # Google OAuth → env-var
```

> `--print` (stdout dump) and `-o FILE` for `fetch` are intentionally absent. Stdout dumps land in AI-agent transcripts; disk writes leave artefacts. The wrapper refuses both.
>
> **Upgrading from 0.3.x?** See [CHANGELOG.md](CHANGELOG.md#040--2026-05-06) for the migration recipe — replace every `--print` with `eval "$(p2ai fetch 'X' --export VAR)"`.

### Write secrets

```bash
p2ai add "<entry>" -u USER                        # auto-generate 24-char password
p2ai add "<entry>" -u USER -g 32                  # custom length
p2ai add "<entry>" -u USER -p                     # type password in your terminal (not chat)
p2ai add "<entry>" --url URL --notes TEXT         # extra fields

p2ai edit "<entry>" -g                            # rotate password
p2ai edit "<entry>" --notes "new"                 # update fields
p2ai edit "<entry>" -t "New Title"                # rename
p2ai mv "<entry>" "Group/Subgroup"                # move between groups
p2ai rm "<entry>" [-f]                            # delete (confirms unless -f)
```

### Session cache (skip Touch-ID for repeated fetches)

```bash
p2ai unlock                          # mode=session: master + entries cached, 5min idle TTL
p2ai unlock --mode per-entry         # paranoid: master never cached; entries cached after first hit
p2ai unlock --ttl 600                # custom idle TTL (hard cap: 30min absolute)
p2ai status                          # mode + remaining TTL + cached entry count
p2ai lock                            # clear everything from RAM
```

Both modes auto-lock on screen-lock, screensaver start, idle timeout, hard cap, or manual `p2ai lock`.

## Requirements

- macOS with Touch-ID enrolled (`bioutil -c` shows ≥1 template)
- `keepassxc-cli` (auto-detected from KeePassXC.app, Homebrew, or `~/bin`)
- Swift toolchain (`xcode-select --install` if missing)

## How it works (security)

Master password lives in macOS Keychain. Every `fetch` triggers `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` → Touch-ID dialog. Biometry is the only auth gate. KeePass DB stays encrypted on disk; master is held in memory for one `keepassxc-cli show` call, then cleared. Clipboard auto-clears after 30s (only if it still holds the secret — won't stomp other copies).

When `p2ai unlock` is used, a short-lived agent (`p2ai-agent`) caches secrets in process RAM for the configured idle TTL. Two modes:

- **`session`** (default): master + per-entry values cached. One Touch-ID at unlock, every subsequent fetch is instant. Same threat model as `ssh-agent` / `sudo` cache.
- **`per-entry`**: master is **never** cached. New entries require fresh Touch-ID; once fetched, that entry's value is cached until idle expiry. Trades a Touch-ID per *unique* entry for never holding the master in long-lived RAM.

The agent listens on a Unix socket (mode 600 in a mode-700 directory) and verifies peer UID via `getpeereid()` so other users on the box can't talk to it. It auto-locks on `com.apple.screenIsLocked`, `com.apple.screensaver.didstart`, idle TTL, hard absolute TTL (30 min), `p2ai lock`, or any termination signal. `rm`/`edit`/`mv` invalidate cached entries automatically so rotations don't linger.

## Caveats — what this tool does NOT protect against

Be honest about scope. Passwort2AI is a **UX layer for LLM-driven workflows** — it removes the "paste your token in chat" anti-pattern that leaks secrets into AI transcripts, prompt logs, screen-shares, and shoulder-surfers. It does **not** harden your machine or your secret store.

It only helps when these all hold:

1. **The LLM agent respects the skill rules** — `p2ai fetch` instead of asking, never echoes values back into the conversation, uses `--export` + `eval` for env-vars. A misbehaving or jailbroken agent can still leak.
2. **Your host is not compromised** — if malware, a rogue extension, or another process can read your RAM, watch your keystrokes, or call `pbpaste`, the agent's RAM cache and the clipboard are both fair game.
3. **The user follows the flow** — calling `p2ai unlock` on a public WiFi café, then walking away without `p2ai lock` (and without the auto-lock screen-lock event firing) leaves a 5-30min RAM window for a passing attacker.

**Out of scope (this tool will not save you):**
- Compromised laptop / unattended unlocked screen / malicious browser extension
- Memory-scraping malware running as your user (can read agent RAM, ssh-agent RAM, anything in-process)
- Physical attacks (cold boot, evil maid, $5 wrench)
- A coerced or buggy LLM that pastes the secret into chat anyway after fetching it correctly
- Phishing pages that ask the user to manually copy a token from KeePass into a fake form
- Backups of your `.kdbx` ending up in iCloud / Dropbox without separate encryption review

**In scope (this tool helps):**
- "Claude needs the Cloudflare token" → fetched silently via Touch-ID, lands in env, never crosses chat
- "Cursor wants me to paste the Stripe key" → no, `p2ai fetch` instead
- Pasting tokens into Slack / GitHub issues / public screen-shares → friction makes you not do it
- Storing a freshly minted secret → `p2ai add` instead of dictating in chat
- Convenience-driven shortcuts that historically led to credentials in `~/.zsh_history`

If your threat model includes #2 or #3 from the previous list, you need a hardware token (YubiKey + KeePassXC Yubikey challenge-response), full-disk encryption with separate key, and SELinux/AppArmor-grade host protection. Passwort2AI is orthogonal to those — it's the layer between your KeePass DB and the AI tools you actually use day-to-day.

## License

MIT — see LICENSE.
