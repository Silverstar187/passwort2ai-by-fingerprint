# Passwort2AI by Fingerprint

<p align="center">
  <img src="docs/touchid-dialog.png" alt="Touch-ID dialog: Passwort2AI is trying to Fetch &quot;Google Cloud API Token&quot;" width="380">
</p>

> **macOS only.** Built on Touch-ID + macOS Keychain + LAContext. Linux/Windows ports would need a different biometric backend (fprintd, Windows Hello) and are out of scope for v0.x.

**Touch-ID → KeePass secret → done.** One tap. No paste. No chat-leak.

```bash
p2ai fetch "Google Cloud API Token"
# 👆 Touch-ID prompt → password in clipboard → auto-clears in 30s
```

## Why this exists

You work with AI agents (Claude Code, Cursor, Copilot). Every time the agent needs a token, you face a bad choice:

- **Paste it into chat** → leaks into transcripts, prompt logs, GitHub issues, screen-shares.
- **Stop and look it up in KeePass manually** → 6 clicks, breaks flow, agent waits.

Passwort2AI removes both. The agent invokes `p2ai fetch '<entry>'`. You touch the sensor. The secret reaches its destination (clipboard, env-var, pipe) without ever appearing in the conversation.

**Net effect:** secrets stay in your KeePass DB. Your AI transcripts stay clean. Your finger is the only thing exposed.

## Setup (3 steps)

```bash
# 1. Install (clones, compiles native binaries, symlinks to ~/.local/bin)
git clone https://github.com/Silverstar187/passwort2ai-by-fingerprint.git ~/.passwort2ai
~/.passwort2ai/install.sh

# 2. Enroll master password + pick your .kdbx via native file dialog
p2ai setup

# 3. (optional) Cache master in agent for 5min idle to skip Touch-ID per fetch
p2ai unlock
```

## Daily use

### Read secrets

```bash
p2ai fetch "<entry>"                              # Touch-ID → clipboard → auto-clear 30s
p2ai fetch "<entry>" --print                      # → stdout (for piping)
p2ai fetch "<entry>" --attr UserName              # any attribute (default: Password)
eval "$(p2ai fetch '<entry>' --export TOKEN)"     # → $TOKEN env-var, no disk-touch
p2ai list [query]                                 # search entries (Touch-ID gated)
p2ai otp "<entry>"                                # current TOTP code → clipboard
p2ai attachment "<entry>" file.json -o out.json   # export file attachment
p2ai gtoken "<sa-entry>" --scope drive.readonly   # mint Google OAuth token from SA-JSON
```

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
