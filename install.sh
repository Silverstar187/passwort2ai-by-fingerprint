#!/usr/bin/env bash
# Passwort2AI installer — chmod scripts + symlink to ~/.local/bin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$HOME/.local/bin}"

mkdir -p "$TARGET"
chmod +x "$SCRIPT_DIR/bin/p2ai-master" "$SCRIPT_DIR/bin/p2ai"

ln -sf "$SCRIPT_DIR/bin/p2ai-master" "$TARGET/p2ai-master"
ln -sf "$SCRIPT_DIR/bin/p2ai"        "$TARGET/p2ai"

printf 'Installed:\n  %s/p2ai\n  %s/p2ai-master\n\n' "$TARGET" "$TARGET"

case ":$PATH:" in
  *":$TARGET:"*) ;;
  *) printf 'Warning: %s is not in $PATH. Add to your shell rc:\n  export PATH="%s:$PATH"\n\n' "$TARGET" "$TARGET" ;;
esac

# macOS sanity checks
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Warning: this tool only runs on macOS (LAContext + Keychain).\n'
fi

if ! command -v swift >/dev/null 2>&1; then
  printf 'Warning: swift not found. Install Xcode Command Line Tools:\n  xcode-select --install\n'
fi

# keepassxc-cli check
if [[ -x "$HOME/bin/keepassxc-cli" ]] || [[ -x "/opt/homebrew/bin/keepassxc-cli" ]] || [[ -x "/usr/local/bin/keepassxc-cli" ]] || [[ -x "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli" ]] || command -v keepassxc-cli >/dev/null 2>&1; then
  :
else
  printf 'Warning: keepassxc-cli not detected. Install:\n  brew install --cask keepassxc\n'
fi

# Touch-ID enrollment hint
if command -v bioutil >/dev/null 2>&1; then
  if bioutil -c 2>/dev/null | grep -q '0 biometric'; then
    printf 'Notice: no fingerprints enrolled. Open:\n  System Settings → Touch ID & Password → Add Fingerprint\n'
  fi
fi

printf '\nNext steps:\n  1. p2ai setup           # one-time master enrollment\n  2. p2ai fetch "<entry>" # Touch-ID → clipboard\n  3. export P2AI_DB=...   # if your .kdbx is not at ~/Passwörter.kdbx\n'
