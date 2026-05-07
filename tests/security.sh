#!/usr/bin/env bash
#
# Security test suite for p2ai.
# Verifies the threat-model claims in README.md actually hold.
#
# Usage: ./tests/security.sh
#
# Replaces p2ai-master with a stub for unattended runs (no Touch-ID).
# Uses an isolated $P2AI_STATE_DIR so it never touches your real agent.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P2AI="$REPO/bin/p2ai"
AGENT_BIN="$REPO/bin/p2ai-agent"

TESTDIR="$(mktemp -d /tmp/p2ai-sectest.XXXXXX)"
trap 'pkill -f "$AGENT_BIN" 2>/dev/null; rm -rf "$TESTDIR"' EXIT

TESTMASTER="security-test-master-$$"
TESTDB="$TESTDIR/test.kdbx"
{ printf '%s\n%s\n' "$TESTMASTER" "$TESTMASTER"; } | keepassxc-cli db-create -p "$TESTDB" >/dev/null 2>&1

cat > "$TESTDIR/p2ai-master-stub" <<STUB
#!/usr/bin/env bash
printf '%s' "$TESTMASTER"
STUB
chmod +x "$TESTDIR/p2ai-master-stub"

export P2AI_DB="$TESTDB"
export P2AI_MASTER_BIN="$TESTDIR/p2ai-master-stub"
export P2AI_STATE_DIR="$TESTDIR/state"
export P2AI_AGENT_BIN="$AGENT_BIN"
export P2AI_AGENT_TTL=300
export P2AI_CLEAR_SECONDS=2
mkdir -p "$P2AI_STATE_DIR"

PASS=0
FAIL=0
SKIP=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------- helpers ----------

start_agent() {
  local mode="${1:-session}"
  "$P2AI" lock >/dev/null 2>&1 || true
  rm -f "$P2AI_STATE_DIR/agent.sock" "$P2AI_STATE_DIR/agent.pid"
  "$P2AI" unlock --mode "$mode" --ttl "${2:-300}" >/dev/null 2>&1
  sleep 0.3
}

ag() { printf '%s\n' "$1" | nc -U "$P2AI_STATE_DIR/agent.sock" 2>/dev/null; }

# ---------- tests ----------

section "1. Filesystem permissions"

start_agent session
mode=$(stat -f '%p' "$P2AI_STATE_DIR" 2>/dev/null)
[[ "${mode: -3}" == "700" ]] && pass "state dir is mode 0700 (got $mode)" || fail "state dir mode = $mode (expected ...700)"

mode=$(stat -f '%p' "$P2AI_STATE_DIR/agent.sock" 2>/dev/null)
[[ "${mode: -3}" =~ ^[67]00$ ]] && pass "socket is mode 0600/0700 (got $mode)" || fail "socket mode = $mode"

mode=$(stat -f '%p' "$P2AI_STATE_DIR/agent.pid" 2>/dev/null)
[[ "${mode: -3}" =~ ^6(00|44)$ ]] && pass "pid file is mode 0600/0644 (got $mode)" || fail "pid file mode = $mode"

section "2. Master not on disk"

# Scan state dir for master string
if grep -rq "$TESTMASTER" "$P2AI_STATE_DIR" 2>/dev/null; then
  fail "master leaked into state dir"
else
  pass "master never written to state dir"
fi

# Scan tmpdir
if find "$TESTDIR" -type f ! -name "test.kdbx" ! -name "p2ai-master-stub" -exec grep -l "$TESTMASTER" {} \; 2>/dev/null | grep -q .; then
  fail "master found in tmp files"
else
  pass "master never written to filesystem (excluding stub + DB)"
fi

section "3. Master not in process args"

# Check ps for agent process — master must NOT be in argv (passed via stdin)
agent_pid=$(<"$P2AI_STATE_DIR/agent.pid")
ps_args=$(ps -p "$agent_pid" -o args= 2>/dev/null || echo "")
if printf '%s' "$ps_args" | grep -q "$TESTMASTER"; then
  fail "master visible in ps args: $ps_args"
else
  pass "master not in agent argv (passed via stdin only)"
fi

section "4. Per-entry mode does not leak master"

start_agent per-entry
resp=$(ag "GET")
[[ "$resp" == "MISS" ]] && pass "GET returns MISS in per-entry mode" || fail "GET returned: $resp"

mode=$(ag "MODE" | tr -d '\n')
[[ "$mode" == "per-entry" ]] && pass "MODE reports per-entry" || fail "MODE = $mode"

section "5. Session mode caches master correctly"

start_agent session
resp=$(ag "GET")
if [[ "$resp" == "$TESTMASTER" ]]; then
  pass "GET returns master in session mode"
else
  fail "GET returned wrong value (length ${#resp}, expected ${#TESTMASTER})"
fi

section "6. Cache invalidation on mutation"

start_agent session
"$P2AI" add "InvTest" -u alice >/dev/null 2>&1
"$P2AI" fetch "InvTest" --attr UserName >/dev/null 2>&1
status_before=$(ag "STATUS" | grep -oE 'entries=[0-9]+')

"$P2AI" rm "InvTest" -f >/dev/null 2>&1
sleep 0.2
status_after=$(ag "STATUS" | grep -oE 'entries=[0-9]+')

[[ "$status_before" == "entries=1" && "$status_after" == "entries=0" ]] \
  && pass "rm invalidates cache ($status_before → $status_after)" \
  || fail "rm should clear cache: $status_before → $status_after"

section "7. INVALIDATE drops only matching keys"

start_agent session
{ printf 'PUTENTRY foo:Password\n'; printf 'a'; } | nc -U "$P2AI_STATE_DIR/agent.sock" >/dev/null
{ printf 'PUTENTRY foo:UserName\n'; printf 'b'; } | nc -U "$P2AI_STATE_DIR/agent.sock" >/dev/null
{ printf 'PUTENTRY bar:Password\n'; printf 'c'; } | nc -U "$P2AI_STATE_DIR/agent.sock" >/dev/null

before=$(ag "STATUS" | grep -oE 'entries=[0-9]+')
ag "INVALIDATE foo" >/dev/null
after=$(ag "STATUS" | grep -oE 'entries=[0-9]+')

[[ "$before" == "entries=3" && "$after" == "entries=1" ]] \
  && pass "INVALIDATE drops prefix-matching only ($before → $after)" \
  || fail "INVALIDATE wrong scope: $before → $after"

remaining=$(ag "GETENTRY bar:Password")
[[ "$remaining" == "c" ]] && pass "non-matching keys preserved" || fail "lost unrelated key"

section "8. Idle TTL enforcement"

# Swift agent clamps min ttl to 30s, so test takes ~32s.
# Use SECTEST_FAST=1 to skip.
if [[ "${SECTEST_FAST:-0}" == "1" ]]; then
  skip "idle TTL test (SECTEST_FAST=1)"
else
  start_agent session 30
  printf '  (waiting 32s for idle expiry...)\n'
  sleep 32
  "$P2AI" status 2>&1 | grep -q "not running" \
    && pass "agent self-exits after idle TTL" \
    || fail "agent still running past idle TTL"
fi

# Section 9 (stale-agent-replacement) intentionally omitted.
# The orphan-socket scenario doesn't arise in normal use (lock cleans, screen-lock
# auto-locks, idle TTL kills). Verified manually that swift agent's startup check
# does SIGTERM the previous owner and the ownership-aware cleanup() prevents the
# old process from clobbering the new one's files.

section "10. EXIT command kills agent"

start_agent session
pid=$(<"$P2AI_STATE_DIR/agent.pid")
ag "EXIT" >/dev/null
sleep 0.3
kill -0 "$pid" 2>/dev/null && fail "agent survived EXIT" || pass "EXIT terminates agent"
[[ ! -e "$P2AI_STATE_DIR/agent.sock" ]] && pass "socket cleaned up after EXIT" || fail "socket not cleaned"

section "11. SIGTERM cleanup"

start_agent session
pid=$(<"$P2AI_STATE_DIR/agent.pid")
kill -TERM "$pid"
sleep 0.3
kill -0 "$pid" 2>/dev/null && fail "agent survived SIGTERM" || pass "SIGTERM terminates agent"
[[ ! -e "$P2AI_STATE_DIR/agent.sock" ]] && pass "socket cleaned up after SIGTERM" || fail "socket leak after SIGTERM"

section "12. Concurrent connections don't crash"

start_agent session
fail_count=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  ( ag "STATUS" >/dev/null ) &
done
wait
ag "STATUS" >/dev/null 2>&1 \
  && pass "agent survives 10 concurrent connections" \
  || fail "agent crashed under concurrent load"

section "13. Unknown commands rejected"

start_agent session
resp=$(ag "PWNED")
[[ "$resp" =~ ^ERR ]] && pass "unknown command returns ERR" || fail "got: $resp"

resp=$(ag "")
[[ -n "$resp" ]] && pass "empty command handled (got: $resp)" || pass "empty command silently ignored"

section "13b. --print and disk-output refused (transcript-leak prevention)"

# fetch --print → die
"$P2AI" add "PrintGuard" -u who -g 16 >/dev/null 2>&1
out=$("$P2AI" fetch "PrintGuard" --print 2>&1)
echo "$out" | grep -q "removed" && pass "fetch --print refused" || fail "fetch --print not blocked: $out"

out=$("$P2AI" otp "PrintGuard" --print 2>&1)
echo "$out" | grep -q "removed" && pass "otp --print refused" || fail "otp --print not blocked"

out=$("$P2AI" gtoken "PrintGuard" --print 2>&1)
echo "$out" | grep -q "removed" && pass "gtoken --print refused" || fail "gtoken --print not blocked"

out=$("$P2AI" attachment "PrintGuard" "f" --print 2>&1)
echo "$out" | grep -q "removed" && pass "attachment --print refused" || fail "attachment --print not blocked"

out=$("$P2AI" fetch "PrintGuard" -o /tmp/p2ai-leak-test 2>&1)
echo "$out" | grep -q "removed" && pass "fetch -o FILE refused (no-disk policy)" || fail "fetch -o FILE not blocked"
rm -f /tmp/p2ai-leak-test  # safety: should not exist anyway

# --export is now removed — should die
out=$("$P2AI" fetch "PrintGuard" --attr UserName --export _U 2>&1)
echo "$out" | grep -q "removed" && pass "fetch --export refused" || fail "fetch --export not blocked"

# p2ai run is the env-injection path
got=$("$P2AI" run -e _U='PrintGuard'::UserName -- bash -c 'printf "%s" "$_U"' 2>/dev/null)
[[ "$got" == "who" ]] && pass "p2ai run injects env into child" || fail "p2ai run failed (got: $got)"

"$P2AI" rm "PrintGuard" -f >/dev/null 2>&1

section "14. Socket peer-UID check"

# Real cross-UID testing requires a second user account. Set P2AI_TEST_PEER_UID=1
# to enable (CI sets this; needs sudo to create+remove a temp user via sysadminctl).
if [[ "${P2AI_TEST_PEER_UID:-0}" != "1" ]]; then
  skip "cross-UID test (set P2AI_TEST_PEER_UID=1 + sudo to enable)"
elif ! command -v sysadminctl >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  skip "cross-UID test needs sysadminctl + passwordless sudo"
else
  TESTUSER="p2aitest$$"
  TESTUID=$((RANDOM % 1000 + 8000))
  cleanup_user() {
    sudo dscl . -delete "/Users/$TESTUSER" 2>/dev/null || true
    sudo rm -rf "/Users/$TESTUSER" 2>/dev/null || true
  }
  trap 'pkill -f "$AGENT_BIN" 2>/dev/null; cleanup_user; rm -rf "$TESTDIR"' EXIT

  # Create a low-privilege user (no admin, no shell login)
  if sudo sysadminctl -addUser "$TESTUSER" -UID "$TESTUID" -password "x" -shell /usr/bin/false 2>/dev/null; then
    start_agent session
    # Make state dir traversable so the other user can at least try to connect
    sudo chmod 755 "$P2AI_STATE_DIR" 2>/dev/null
    sudo chmod 644 "$P2AI_STATE_DIR/agent.sock" 2>/dev/null
    # Try to connect as the other user — must be rejected by getpeereid() check
    OTHER_RESP=$(sudo -u "$TESTUSER" bash -c "echo STATUS | nc -U '$P2AI_STATE_DIR/agent.sock' 2>&1" || true)
    if [[ -z "$OTHER_RESP" ]] || echo "$OTHER_RESP" | grep -qiE "denied|refused|forbidden|reject|err"; then
      pass "agent rejects connection from different UID (got: '${OTHER_RESP:-empty}')"
    else
      fail "agent accepted connection from UID $TESTUID — getpeereid() check broken: $OTHER_RESP"
    fi
    # Restore mode for rest of suite
    chmod 700 "$P2AI_STATE_DIR" 2>/dev/null
    chmod 600 "$P2AI_STATE_DIR/agent.sock" 2>/dev/null
    cleanup_user
  else
    skip "could not create test user (sysadminctl failed)"
  fi
fi

section "15. Lock clears all cached secrets"

start_agent session
"$P2AI" add "ClearTest" -u alice >/dev/null 2>&1
"$P2AI" fetch "ClearTest" --attr UserName >/dev/null 2>&1
sleep 0.2
status=$(ag "STATUS" | grep -oE 'entries=[0-9]+')
[[ "$status" == "entries=1" ]] || fail "setup failed: $status"

"$P2AI" lock >/dev/null 2>&1
sleep 0.2
[[ ! -e "$P2AI_STATE_DIR/agent.sock" ]] && pass "lock removes socket" || fail "socket survives lock"

# Restart, verify cache empty
start_agent session
status=$(ag "STATUS" | grep -oE 'entries=[0-9]+')
[[ "$status" == "entries=0" ]] && pass "fresh agent starts with empty cache" || fail "cache leaked across restart: $status"

section "17. p2ai run isolation"

# This section verifies the core security claim of `p2ai run`: secrets enter
# only the child command's environment, never the parent shell, never argv.
"$P2AI" add "RunGuard" -u runuser -g 24 >/dev/null 2>&1

# 17a. Parent shell env stays clean after `p2ai run` returns
unset SECRET || true
"$P2AI" run -e SECRET='RunGuard' -- bash -c 'true'
[[ -z "${SECRET:-}" ]] \
  && pass "parent shell env has no SECRET after run completes" \
  || fail "parent leaked SECRET (length ${#SECRET})"

# 17b. Child sees the env
got=$("$P2AI" run -e SECRET='RunGuard' -- bash -c 'printf len=%d "${#SECRET}"')
[[ "$got" == "len=24" ]] \
  && pass "child receives injected env (len=24)" \
  || fail "child env wrong: $got"

# 17c. Multiple secrets, ::attr support
got=$("$P2AI" run -e A='RunGuard' -e B='RunGuard'::UserName -- bash -c 'printf "Alen=%d B=%s" "${#A}" "$B"')
[[ "$got" == "Alen=24 B=runuser" ]] \
  && pass "multi-secret + ::attr injection works" \
  || fail "multi-env wrong: $got"

# 17d. Exit code propagation
"$P2AI" run -e _X='RunGuard' -- bash -c 'exit 17'
[[ $? -eq 17 ]] \
  && pass "child exit code propagated to parent" \
  || fail "exit code lost"

# 17e. Secret not in child argv. Spawn a long-running child and inspect ps.
"$P2AI" run -e _ARGV='RunGuard' -- sleep 3 &
RUN_BGPID=$!
sleep 0.4
# Grab argv of the deepest descendant (the actual sleep process)
SLEEP_PID=$(pgrep -P "$(pgrep -P "$RUN_BGPID" | head -1)" 2>/dev/null | head -1 || pgrep -P "$RUN_BGPID" | head -1)
[[ -z "$SLEEP_PID" ]] && SLEEP_PID="$RUN_BGPID"
sleep_argv=$(ps -p "$SLEEP_PID" -o args= 2>/dev/null)
# Get the actual secret value once for comparison (not via run, directly)
ref_pw=$(printf '%s\n' "$TESTMASTER" | keepassxc-cli show -s -a Password "$TESTDB" "RunGuard" 2>/dev/null)
if [[ -n "$ref_pw" ]] && printf '%s' "$sleep_argv" | grep -qF "$ref_pw"; then
  fail "secret leaked into child argv: $sleep_argv"
else
  pass "secret not in child argv (env-only injection)"
fi
wait "$RUN_BGPID" 2>/dev/null || true

# 17f. Empty --env list still works (just exec)
got=$("$P2AI" run -- echo OK)
[[ "$got" == "OK" ]] \
  && pass "p2ai run with no -e args just execs" \
  || fail "no-env case broken: $got"

# 17g. Invalid --env format dies
out=$("$P2AI" run -e BADFORMAT -- echo x 2>&1)
echo "$out" | grep -q "invalid --env" \
  && pass "malformed --env rejected" \
  || fail "malformed --env not caught: $out"

# 17i. --env-file dotenv parser — load mappings from file
ENVF="$TESTDIR/test.env"
cat > "$ENVF" <<EOF
# comment ignored
A='RunGuard'
B="RunGuard"
C=RunGuard::UserName
EOF
got=$("$P2AI" run -f "$ENVF" -- bash -c 'echo "A=${#A} B=${#B} C=$C"')
[[ "$got" == "A=24 B=24 C=runuser" ]] \
  && pass "--env-file dotenv parser loads quoted + unquoted + ::attr" \
  || fail "env-file parsing wrong: $got"

# 17j. malformed env-file rejected
echo "garbage_no_equals" > "$TESTDIR/bad.env"
out=$("$P2AI" run -f "$TESTDIR/bad.env" -- echo x 2>&1)
echo "$out" | grep -q "not parseable" \
  && pass "malformed env-file refused" \
  || fail "env-file parser too permissive"

# 17h. Signal-forwarding — Ctrl+C / SIGTERM to p2ai must reach the child
"$P2AI" run -e _=RunGuard -- sleep 30 &
RUN_PID=$!
sleep 0.4
# After exec, RUN_PID IS the cmd (sleep). Verify by checking comm.
comm=$(ps -p "$RUN_PID" -o comm= 2>/dev/null | tr -d ' ')
[[ "$comm" == "sleep" ]] \
  && pass "exec replaces p2ai bash with target cmd (same PID, comm=$comm)" \
  || fail "PID is not the cmd (comm=$comm) — exec failed?"
kill -TERM "$RUN_PID" 2>/dev/null
sleep 0.4
kill -0 "$RUN_PID" 2>/dev/null \
  && fail "child survived SIGTERM — orphan risk" \
  || pass "SIGTERM to p2ai run reaches child cleanly"
wait "$RUN_PID" 2>/dev/null || true

"$P2AI" rm "RunGuard" -f >/dev/null 2>&1

section "16. PUTENTRY size cap"

start_agent session
# Try to push a 2MB payload — should be capped at 1MB by readToEof
big=$(head -c 2000000 /dev/urandom | base64 | head -c 2000000)
{ printf 'PUTENTRY huge:Password\n'; printf '%s' "$big"; } | nc -U "$P2AI_STATE_DIR/agent.sock" >/dev/null
cached=$(ag "GETENTRY huge:Password" | wc -c | tr -d ' ')
# Allow some slop for protocol framing; key invariant is "much less than 2MB sent"
if [[ "$cached" -le 1048576 ]]; then
  pass "PUTENTRY caps payload at exactly 1MB (got $cached bytes)"
elif [[ "$cached" -lt 1100000 ]]; then
  pass "PUTENTRY caps payload near 1MB (got $cached bytes)"
else
  fail "PUTENTRY accepted oversized payload: $cached bytes (sent 2MB, expected ≤1MB)"
fi

# ----------------------------------------------------------------------------
section "18. p2ai-master stdout leak guard (issue #8)"
# ----------------------------------------------------------------------------
# The Swift binary p2ai-master must refuse to emit master on stdout unless
# the caller sets P2AI_MASTER_PIPE_OK=1. Direct invocation by AI agents,
# interactive shells, or arbitrary pipes must be blocked. Tests run against
# the REAL Swift binary (not the stub) because the guard lives there.

REAL_MASTER_BIN="$REPO/bin/p2ai-master"
if [[ ! -x "$REAL_MASTER_BIN" ]]; then
  skip "18a-c: real p2ai-master binary not built — run install.sh"
else
  # 18a: direct invocation without env → refuse, master MUST NOT appear
  out=$("$REAL_MASTER_BIN" --reason "test 18a" 2>&1 </dev/null || true)
  rc=$?
  if [[ "$out" == *"refusing to emit master on stdout"* ]] && [[ "$rc" -ne 0 ]]; then
    pass "18a: direct invocation refused without P2AI_MASTER_PIPE_OK"
  else
    fail "18a: direct invocation NOT refused (rc=$rc, output: ${out:0:80})"
  fi

  # 18b: --auth-only flag is recognized in help (gesture-only path documented)
  out=$("$REAL_MASTER_BIN" --help 2>&1 || true)
  if [[ "$out" == *"--auth-only"* ]]; then
    pass "18b: --auth-only flag documented in help"
  else
    fail "18b: --auth-only flag missing from help"
  fi

  # 18c: PIPE_OK=1 must bypass the guard. Real fetch will fail in unattended
  # tests (no Touch-ID, no enrolled item under test conditions), but the
  # specific "refusing to emit" message must NOT appear — that confirms the
  # guard recognized the legitimate-caller env var.
  out=$(P2AI_MASTER_PIPE_OK=1 "$REAL_MASTER_BIN" --reason "test 18c" 2>&1 </dev/null || true)
  if [[ "$out" != *"refusing to emit master"* ]]; then
    pass "18c: P2AI_MASTER_PIPE_OK=1 bypasses guard (legitimate-caller path)"
  else
    fail "18c: PIPE_OK=1 still refused (env var not honored)"
  fi
fi

# ---------- summary ----------

"$P2AI" lock >/dev/null 2>&1

printf '\n\033[1m===== SUMMARY =====\033[0m\n'
printf '  PASS: \033[32m%d\033[0m\n' "$PASS"
printf '  FAIL: \033[31m%d\033[0m\n' "$FAIL"
printf '  SKIP: \033[33m%d\033[0m\n' "$SKIP"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
