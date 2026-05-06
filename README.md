# Passwort2AI by Fingerprint

**Touch-ID → KeePass secret → done.** One tap. No paste. No chat-leak.

```bash
p2ai fetch "Cloudflare API Token"
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
# 1. Install
git clone https://github.com/Silverstar187/passwort2ai-by-fingerprint.git ~/.passwort2ai
~/.passwort2ai/install.sh

# 2. Enroll master password (one-time, hidden input)
p2ai setup

# 3. (optional) Point at your .kdbx if it's not ~/Passwörter.kdbx
echo 'export P2AI_DB="$HOME/your-database.kdbx"' >> ~/.zshrc
```

## Daily use

```bash
p2ai fetch "<entry>"                              # Touch-ID → clipboard → auto-clear 30s
p2ai fetch "<entry>" --print                      # → stdout (for piping)
eval "$(p2ai fetch '<entry>' --export TOKEN)"     # → $TOKEN env-var, no disk-touch
p2ai list <fuzzy>                                 # search entries (Touch-ID gated)
```

## Requirements

- macOS with Touch-ID enrolled (`bioutil -c` shows ≥1 template)
- `keepassxc-cli` (auto-detected from KeePassXC.app, Homebrew, or `~/bin`)
- Swift toolchain (`xcode-select --install` if missing)

## How it works (security)

Master password lives in macOS Keychain. Every `fetch` triggers `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` → Touch-ID dialog. Biometry is the only auth gate. KeePass DB stays encrypted on disk; master is held in memory for one `keepassxc-cli show` call, then cleared. Clipboard auto-clears after 30s (only if it still holds the secret — won't stomp other copies).

## License

MIT — see LICENSE.
