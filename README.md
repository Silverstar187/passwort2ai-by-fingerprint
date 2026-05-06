# Passwort2AI by Fingerprint

<p align="center">
  <img src="docs/touchid-dialog.png" alt="Touch-ID dialog: Passwort2AI is trying to Fetch &quot;Google Cloud API Token&quot;" width="380">
</p>

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

```bash
p2ai fetch "<entry>"                              # Touch-ID → clipboard → auto-clear 30s
p2ai fetch "<entry>" --print                      # → stdout (for piping)
eval "$(p2ai fetch '<entry>' --export TOKEN)"     # → $TOKEN env-var, no disk-touch
p2ai list <fuzzy>                                 # search entries (Touch-ID gated)

# Session caching (sudo-style — Touch-ID once, fetch many times)
p2ai unlock [--ttl 300]    # default idle TTL 5min, hard cap 30min absolute
p2ai status                # show remaining TTL
p2ai lock                  # clear master from RAM
```

## Requirements

- macOS with Touch-ID enrolled (`bioutil -c` shows ≥1 template)
- `keepassxc-cli` (auto-detected from KeePassXC.app, Homebrew, or `~/bin`)
- Swift toolchain (`xcode-select --install` if missing)

## How it works (security)

Master password lives in macOS Keychain. Every `fetch` triggers `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` → Touch-ID dialog. Biometry is the only auth gate. KeePass DB stays encrypted on disk; master is held in memory for one `keepassxc-cli show` call, then cleared. Clipboard auto-clears after 30s (only if it still holds the secret — won't stomp other copies).

When `p2ai unlock` is used, a short-lived agent (`p2ai-agent`) caches the master in process RAM for the configured idle TTL. The agent listens on a Unix socket (mode 600 in a mode-700 directory) and verifies peer UID via `getpeereid()`. It auto-locks on `com.apple.screenIsLocked` / `com.apple.screensaver.didstart` Distributed Notifications, on hard absolute TTL (30 min default), or on `p2ai lock`. Same threat model as `ssh-agent` / `sudo` cache.

## License

MIT — see LICENSE.
