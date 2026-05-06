# Passwort2AI by Fingerprint

<p align="center">
  <img src="docs/touchid-dialog.png" alt="Touch-ID dialog: Passwort2AI is trying to Fetch &quot;Google Cloud API Token&quot;" width="380">
</p>

## Alle deine Secrets — leak-sicher per Fingerabdruck dem LLM übergeben.

Du bist Dev. Du hast 30+ Tokens, API-Keys, DB-Passwörter. Jeder Coding-Agent (Claude Code, Cursor, Aider, Cline, Copilot) will mindestens einen davon. Bisher sind alle Wege scheiße:

- **`.env`-Files überall** — verstreut auf 20 Repos, manche im Git-Index gelandet, secret-rotation = händische Suche
- **Passwort-Manager → Chat-Paste** — LLM sieht Klartext, landet im Transcript, in Prompt-Logs, in Anthropic/OpenAI Servern, im Browser-Cache, möglicherweise im LLM-Training-Set
- **Copy + "es ist in clipboard"** — AI muss `pbpaste` aufrufen, manuelle Schritte, Wert lebt in Clipboard-Historie + Universal Clipboard zu deinem iPhone, two-key-combo `Cmd+C → Cmd+V` reicht für Daumen-Fehler in falsches Fenster
- **Hardcoded für "kurz testen"** — kommt nie raus, in Git Blame foreverr

> **p2ai löst alle vier:** ein Vault (dein KeePass `.kdbx`), ein Finger-Tap, Wert geht direkt in die Tool-Env des Child-Prozesses. LLM sieht den Klartext nie. Disk sieht ihn nie. Clipboard wird (default) nicht mal benutzt.

```bash
p2ai run -e GH_TOKEN='GitHub Token' -- gh repo list
# 👆 Touch-ID → token nur in gh's env → kein Chat-Leak, kein Disk-Leak
```

**Eine Taste statt zwei. Kein Leak statt jedes Mal Leak.**

## Why this exists

AI coding agents brauchen Tokens. Standard-Workflow heute = User pastet ihn in Chat. Damit ist der Token:
- im Conversation-Transcript (Anthropic / OpenAI / Cursor server)
- in lokalen Prompt-Logs
- in Screen-Recordings, Pair-Programming-Sessions, Demo-Streams
- möglicherweise in Trainings-Daten zukünftiger Modelle

p2ai entfernt diesen einen Anti-Pattern und ersetzt ihn durch Touch-ID-gated env-injection: der Agent ruft `p2ai run -e ...` auf, du tappst den Sensor, das Tool sieht den Wert in seiner Environment, niemand sonst.

## How

ssh-agent-Modell für KeePass, gegated durch Touch-ID. Wraps `keepassxc-cli`. Master-Passwort lebt nur in der macOS Keychain (release via `LAContext`). Optional in-RAM-Agent cached Secrets damit wiederholte Aufrufe den Prompt skippen.

- **Read** — `fetch`, `list`, `otp`, `attachment`, `gtoken`
- **Run** — `run` (env-injection in child only)
- **Write** — `add`, `edit`, `rm`, `mv`
- **Session** — `unlock` / `status` / `lock`

**Tastenanzahl im Vergleich:**

| Workflow | Tasten | Leak-Vektoren |
|---|---|---|
| Copy-paste in Chat | `Cmd+Tab` → `Cmd+C` → `Cmd+Tab` → `Cmd+V` (4) | Chat-Transcript, server-side logs, training data |
| `pbpaste` + AI-prompt | manuell `Cmd+C` (1) + AI-Prompt schreiben (n) | Clipboard-history, Universal Clipboard zu iPhone |
| **`p2ai run`** | **1 Touch-ID-Tap** | **0** — Wert geht direkt in Child-Env |

## What it isn't

- Not a replacement for KeePass — dein `.kdbx` bleibt die Source of Truth.
- Not new crypto — Decryption ist `keepassxc-cli`.
- Not host hardening — selber Trust-Model wie `ssh-agent`. Siehe [Scope](#scope).

> **macOS only.** Gebaut auf Touch-ID + Keychain + `LAContext`.

## Install

```bash
brew install silverstar187/p2ai/passwort2ai
p2ai setup
```

That's it. `p2ai setup` enrolls your master into the macOS Keychain and picks your `.kdbx` via a native file dialog.

For **AI agents** (Claude Code, Cursor, Aider, Cline) drop the rules file:

```bash
p2ai system-prompt > .cursorrules        # or >> CLAUDE.md / .aider.conf.yml
```

<details>
<summary>Install from source instead</summary>

```bash
git clone --branch v0.5.0 --depth 1 https://github.com/Silverstar187/passwort2ai-by-fingerprint.git ~/.passwort2ai
~/.passwort2ai/install.sh
p2ai setup
```

`--branch v0.5.0` pins to a reviewable commit SHA. `install.sh` compiles the Swift binaries and links `p2ai` into `~/.local/bin`.
</details>

## Daily use

Two egress paths only — neither lets the secret reach the parent shell or disk:
**`p2ai run`** for tool invocations (env-injection only into the child), **`p2ai fetch`** for clipboard hand-off (default pbcopy + auto-clear).

```bash
# Run a tool with secrets injected (PRIMARY pattern)
p2ai run -e GH_TOKEN='GitHub Token' -- gh repo list
p2ai run -e DB='Postgres Prod' -- psql
p2ai run -e A='AWS Key' -e B='AWS Secret' -- aws s3 ls
p2ai run -e USR='Service'::UserName -- some-tool   # specific attribute via ::

# Fetch to clipboard (for human paste)
p2ai fetch "<entry>"                              # → clipboard, auto-clear 30s
p2ai fetch "<entry>" --attr UserName              # any attribute (default: Password)
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

> `--print`, `-o FILE` for fetch, and `--export` are intentionally absent. Each was a transcript-leak path. The wrapper refuses them with a pointer to `p2ai run`. Upgrading from 0.4.x? Replace `eval "$(p2ai fetch X --export V)" && tool` with `p2ai run -e V='X' -- tool`. Full migration in [CHANGELOG.md](CHANGELOG.md#050--2026-05-06).

## Requirements

- macOS with Touch-ID enrolled (`bioutil -c` shows ≥1 template)
- `keepassxc-cli` (auto-detected from KeePassXC.app, Homebrew, or `~/bin`)

## Security

Master password lives in macOS Keychain. Every `fetch` triggers `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` → Touch-ID dialog. The KeePass DB stays encrypted on disk. The master is held in shell-variable scope for one `keepassxc-cli` call, then cleared.

`p2ai unlock` spawns a short-lived agent (`p2ai-agent`) that caches secrets in process RAM with idle TTL + 30-min hard cap. The agent listens on a Unix socket (mode 600 in a mode-700 dir) and verifies peer UID via `getpeereid()`. Auto-locks on `com.apple.screenIsLocked`, `com.apple.screensaver.didstart`, idle expiry, hard cap, or `p2ai lock`. `rm` / `edit` / `mv` invalidate cached entries so rotations don't linger.

Two modes:
- `session` (default) — master + per-entry values cached. One Touch-ID at unlock; every subsequent fetch is instant. Threat model = `ssh-agent` / `sudo` cache.
- `per-entry` — master is never cached. New entries need a fresh Touch-ID; fetched entries are cached until idle expiry.

## Scope

p2ai sits **between your KeePass DB and the AI tools you use day-to-day**. It eliminates one specific anti-pattern: pasting secrets in chat. It does not replace KeePass, FDE, or your hardware token — those layers still apply if you need them.

Trust model: same as `ssh-agent` / `sudo` cache. The agent holds secrets in process RAM with idle TTL, hard cap, and auto-lock on screen-lock. A compromised host or another same-user process can read agent RAM, the clipboard, or env-vars (via `ps e` / memory dump) — same constraint as every credential helper. For tighter isolation use `--mode per-entry` (master is never cached) or `p2ai lock` after each session.

## License

MIT — see [LICENSE](LICENSE).
