#!/usr/bin/env bash
# Passwort2AI installer — compile, install, wire up agents, run setup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$HOME/.local/bin}"
SRC="$SCRIPT_DIR/src"
BIN="$SCRIPT_DIR/bin"

# ── Helpers ───────────────────────────────────────────────────────────────────
header() { printf '\n  ══ %s ══\n' "$*"; }
step()   { printf '  ✓ %s\n' "$*"; }
warn()   { printf '  ⚠ %s\n' "$*"; }
ask()    { printf '\n  %s [Y/n] ' "$*"; read -r ans; [[ "${ans:-y}" =~ ^[yY]$ ]]; }

printf '\n'
printf '  ┌─────────────────────────────────────────────────────────────┐\n'
printf '  │  Passwort2AI by Fingerprint — Installer                    │\n'
printf '  └─────────────────────────────────────────────────────────────┘\n'

# ── macOS check ───────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "This tool only runs on macOS (Touch ID + Keychain)."
  exit 1
fi

# ── keepassxc-cli ─────────────────────────────────────────────────────────────
header "Step 1/4: Dependencies"
if ! command -v keepassxc-cli >/dev/null 2>&1 && \
   [[ ! -x "/opt/homebrew/bin/keepassxc-cli" && ! -x "/usr/local/bin/keepassxc-cli" && \
      ! -x "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli" ]]; then
  if command -v brew >/dev/null 2>&1; then
    printf '  Installing KeePassXC via Homebrew...\n'
    brew install --cask keepassxc
    step "KeePassXC installed"
  else
    warn "keepassxc-cli not found and brew not available."
    warn "Install manually: https://keepassxc.org/download/"
    exit 1
  fi
else
  step "KeePassXC found"
fi

# Touch ID check
if command -v bioutil >/dev/null 2>&1; then
  if bioutil -c 2>/dev/null | grep -q '0 biometric'; then
    warn "No fingerprint enrolled."
    printf '  → System Settings → Touch ID & Password → Add Fingerprint\n'
    exit 1
  else
    step "Touch ID ready"
  fi
fi

# ── Compile ───────────────────────────────────────────────────────────────────
header "Step 2/4: Compiling"
mkdir -p "$TARGET"
mkdir -p "$BIN"
chmod +x "$BIN/p2ai"

if ! command -v swiftc >/dev/null 2>&1; then
  warn "swiftc not found. Install Xcode Command Line Tools:"
  printf '  xcode-select --install\n'
  exit 1
fi

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
  [[ -f "$SRC/$name.swift" ]] || { printf '  Error: %s/%s.swift missing.\n' "$SRC" "$name" >&2; exit 1; }
  printf '  Compiling %s …\n' "$name"
  swiftc "$SRC/$name.swift" -o "$BIN/$name" -O \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST"
  codesign -s - --force "$BIN/$name" 2>/dev/null || true
done
rm -f "$PLIST"

ln -sf "$BIN/p2ai-master" "$TARGET/p2ai-master"
ln -sf "$BIN/p2ai-agent"  "$TARGET/p2ai-agent"
ln -sf "$BIN/p2ai"        "$TARGET/p2ai"
step "Binaries installed → $TARGET"

# ── PATH ──────────────────────────────────────────────────────────────────────
case ":$PATH:" in
  *":$TARGET:"*) step "PATH already set" ;;
  *)
    SHELL_RC=""
    if [[ -f "$HOME/.zshrc" ]];  then SHELL_RC="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then SHELL_RC="$HOME/.bashrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then SHELL_RC="$HOME/.bash_profile"
    fi
    if [[ -n "$SHELL_RC" ]]; then
      printf '\nexport PATH="%s:$PATH"\n' "$TARGET" >> "$SHELL_RC"
      step "Added $TARGET to PATH in $SHELL_RC"
      export PATH="$TARGET:$PATH"
    else
      warn "Could not find shell rc. Add manually: export PATH=\"$TARGET:\$PATH\""
    fi
    ;;
esac

# ── Claude Code skill ─────────────────────────────────────────────────────────
header "Step 3/4: AI Agent Integration"
CLAUDE_SKILLS="$HOME/.claude/skills"
if [[ -d "$HOME/.claude" ]]; then
  mkdir -p "$CLAUDE_SKILLS"
  ln -sf "$SCRIPT_DIR/SKILL.md" "$CLAUDE_SKILLS/passwort2ai.md"
  step "Claude Code skill installed → $CLAUDE_SKILLS/passwort2ai.md"
else
  step "Claude Code not detected — skipping skill install"
fi

printf '\n  For other agents, run once per project:\n'
printf '    Cursor:  p2ai system-prompt --target cursor >> .cursorrules\n'
printf '    Cline:   p2ai system-prompt --target cline  >> .clinerules\n'
printf '    Aider:   p2ai system-prompt --target aider  >> .aider.conf.yml\n'

# ── Setup ─────────────────────────────────────────────────────────────────────
header "Step 4/4: First-Time Setup"
printf '\n  p2ai setup will:\n'
printf '    • Ask you to choose a master password\n'
printf '    • Show a macOS dialog → click "Always Allow"\n'
printf '    • Create your password database automatically\n'

if ask "Run p2ai setup now?"; then
  printf '\n'
  "$TARGET/p2ai" setup
else
  printf '\n  Run manually when ready: p2ai setup\n'
fi

printf '\n  ✓ All done. Try: p2ai unlock && p2ai add "My First Entry"\n\n'
