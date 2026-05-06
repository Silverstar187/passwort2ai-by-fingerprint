# Passwort2AI by Fingerprint

Touch-ID-gated KeePass secret retrieval for terminals and AI agents on macOS.
One fingerprint tap → secret in clipboard or piped to your next command.

```bash
p2a fetch "Cloudflare API Token"        # Touch-ID → pbcopy → auto-clear 30s
eval "$(p2a fetch 'CF Token' --export CF_TOKEN)" && wrangler deploy && unset CF_TOKEN
```

## Setup (3 steps)

```bash
# 1. Install
git clone https://github.com/Silverstar187/passwort2ai-by-fingerprint.git ~/.passwort2ai
~/.passwort2ai/install.sh

# 2. Enroll master password (one-time, hidden input)
p2a setup

# 3. Configure your KeePassXC database path (default: ~/Passwörter.kdbx)
echo 'export P2A_DB="$HOME/your-database.kdbx"' >> ~/.zshrc
```

Done. Now `p2a fetch "<entry>"` taps Touch-ID and copies the password.

## Requirements

- macOS with Touch-ID enrolled (`bioutil -c` shows ≥1 template)
- `keepassxc-cli` (auto-detected from KeePassXC.app, Homebrew, or `~/bin`)
- Swift toolchain (preinstalled with Xcode Command Line Tools)

## License

MIT — see LICENSE.
