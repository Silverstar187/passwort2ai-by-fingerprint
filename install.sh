#!/usr/bin/env bash
# Passwort2AI installer — compile Swift sources, codesign, symlink to ~/.local/bin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$HOME/.local/bin}"
SRC="$SCRIPT_DIR/src"
BIN="$SCRIPT_DIR/bin"

mkdir -p "$TARGET" "$BIN"

# Bash CLI is not compiled, just chmod
chmod +x "$BIN/p2ai"

# macOS sanity check
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Warning: this tool only runs on macOS (LAContext + Keychain).\n'
fi

# Compile Swift sources to native arm64/x86_64 binaries with bundle name
# "Passwort2AI" so Touch-ID dialog shows "Passwort2AI is trying to: …" instead
# of "swift is trying to: …".
if command -v swiftc >/dev/null 2>&1; then
  PLIST="$(mktemp -t p2ai-info.XXXXXX.plist)"
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Passwort2AI</string>
  <key>CFBundleDisplayName</key><string>Passwort2AI</string>
  <key>CFBundleIdentifier</key><string>ai.nexperts.passwort2ai</string>
  <key>CFBundleVersion</key><string>0.2.0</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
</dict>
</plist>
EOF

  for name in p2ai-master p2ai-agent; do
    if [[ ! -f "$SRC/$name.swift" ]]; then
      printf 'Error: %s/%s.swift missing.\n' "$SRC" "$name" >&2; exit 1
    fi
    printf 'Compiling %s …\n' "$name"
    swiftc "$SRC/$name.swift" -o "$BIN/$name" -O \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST"
    codesign -s - --force "$BIN/$name" 2>/dev/null || true
  done
  rm -f "$PLIST"
else
  printf 'Error: swiftc not found. Install Xcode Command Line Tools:\n  xcode-select --install\n' >&2
  exit 1
fi

ln -sf "$BIN/p2ai-master" "$TARGET/p2ai-master"
ln -sf "$BIN/p2ai-agent"  "$TARGET/p2ai-agent"
ln -sf "$BIN/p2ai"        "$TARGET/p2ai"

printf 'Installed:\n  %s/p2ai\n  %s/p2ai-master\n  %s/p2ai-agent\n\n' "$TARGET" "$TARGET" "$TARGET"

case ":$PATH:" in
  *":$TARGET:"*) ;;
  *) printf 'Warning: %s is not in $PATH. Add to your shell rc:\n  export PATH="%s:$PATH"\n\n' "$TARGET" "$TARGET" ;;
esac

if [[ ! -x "$HOME/bin/keepassxc-cli" && ! -x "/opt/homebrew/bin/keepassxc-cli" && ! -x "/usr/local/bin/keepassxc-cli" && ! -x "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli" ]] && ! command -v keepassxc-cli >/dev/null 2>&1; then
  printf 'Warning: keepassxc-cli not detected. Install:\n  brew install --cask keepassxc\n'
fi

if command -v bioutil >/dev/null 2>&1; then
  if bioutil -c 2>/dev/null | grep -q '0 biometric'; then
    printf 'Notice: no fingerprints enrolled. Open:\n  System Settings → Touch ID & Password → Add Fingerprint\n'
  fi
fi

printf '\nNext steps:\n  1. p2ai setup           # one-time master enrollment\n  2. p2ai unlock          # Touch-ID, master cached in agent (5min idle)\n  3. p2ai fetch "<entry>" # cached → no Touch-ID until idle expires\n'
