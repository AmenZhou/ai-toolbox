#!/usr/bin/env bash
# test-run-job.sh — unit tests for .orchestrate/bin/run-job.sh dispatch logic
# Uses mock cursor/claude binaries; does not invoke real agents.
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
RUN_JOB_SRC="${RUN_JOB_SRC:-/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/run-job.sh}"
RUN_JOB="${RUN_JOB:-$PROJECT_ROOT/bin/run-job.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; return 0; }  # return 0: an EXIT trap must never clobber the script's exit status
trap cleanup EXIT

setup_mocks() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-job-test.XXXXXX")"
  MOCK_CURSOR="$TMP/cursor-agent"
  MOCK_CLAUDE="$TMP/claude"
  LOG_CURSOR="$TMP/cursor.log"
  LOG_CLAUDE="$TMP/claude.log"
  CONF="$TMP/agent.conf"
  WORK="$TMP/work"
  mkdir -p "$WORK"

  cat > "$MOCK_CURSOR" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$LOG_CURSOR"
echo "cursor-agent mock: \$*"
EOF
  cat > "$MOCK_CLAUDE" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$LOG_CLAUDE"
echo "claude mock: \$*"
EOF
  chmod +x "$MOCK_CURSOR" "$MOCK_CLAUDE"
}

write_conf() {
  local runner="$1"
  cat > "$CONF" << EOF
RUNNER=$runner
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
}

run_job() {
  local job="$1"
  rm -f "$LOG_CURSOR" "$LOG_CLAUDE"
  (cd "$WORK" && ORCHESTRATE_AGENT_CONF="$CONF" bash "$RUN_JOB" "$job")
}

assert_cursor_args() {
  local expected="$1"
  if [[ ! -f "$LOG_CURSOR" ]]; then
    fail "cursor mock not invoked — expected: $expected"
    return
  fi
  local got
  got="$(tr '\n' ' ' < "$LOG_CURSOR" | sed 's/  */ /g;s/ $//')"
  if [[ "$got" == *"$expected"* ]]; then
    ok "cursor dispatched: $expected"
  else
    fail "cursor args mismatch — got '$got', want '$expected'"
  fi
  if [[ -f "$LOG_CLAUDE" ]]; then
    fail "claude mock should not run when RUNNER=cursor"
  fi
}

assert_claude_args() {
  local expected="$1"
  if [[ ! -f "$LOG_CLAUDE" ]]; then
    fail "claude mock not invoked — expected: $expected"
    return
  fi
  local got
  got="$(tr '\n' ' ' < "$LOG_CLAUDE" | sed 's/  */ /g;s/ $//')"
  if [[ "$got" == *"$expected"* ]]; then
    ok "claude dispatched: $expected"
  else
    fail "claude args mismatch — got '$got', want '$expected'"
  fi
  if [[ -f "$LOG_CURSOR" ]]; then
    fail "cursor mock should not run when RUNNER=claude"
  fi
}

assert_exit_fail() {
  local job="$1"
  local label="$2"
  set +e
  run_job "$job" >/dev/null 2>&1
  local code=$?
  set -e
  if [[ "$code" -ne 0 ]]; then
    ok "$label (exit $code)"
  else
    fail "$label — expected non-zero exit"
  fi
}

echo ""
echo "── run-job.sh dispatch — test suite ─────────────"

echo ""
echo "0. Prerequisites"
if [[ -f "$RUN_JOB" ]]; then
  ok "run-job.sh found at $RUN_JOB"
else
  fail "run-job.sh missing at $RUN_JOB"
  echo "  aborting — cannot run dispatch tests"
  exit 1
fi

if [[ -f "$RUN_JOB_SRC" ]] && cmp -s "$RUN_JOB_SRC" "$RUN_JOB" 2>/dev/null; then
  ok "installed run-job.sh matches ai-toolbox source"
elif [[ -f "$RUN_JOB_SRC" ]]; then
  fail "installed run-job.sh stale — run install-launchd.sh"
fi

if grep -q 'cleanup_stale_inbox' "$RUN_JOB" && [[ -x "$PROJECT_ROOT/bin/cleanup-stale-inbox.sh" ]]; then
  ok "run-job.sh invokes cleanup-stale-inbox.sh before tend"
else
  fail "run-job.sh missing cleanup_stale_inbox hook or cleanup script not executable"
fi

setup_mocks

echo ""
echo "1. RUNNER=cursor tend"
write_conf cursor
run_job tend
assert_cursor_args "-p --trust /task-orchestrate tend go auto"

echo ""
echo "2. RUNNER=claude tend"
write_conf claude
run_job tend
assert_claude_args "-p tend go auto"

echo ""
echo "2b. TEND_MODE=notify (override)"
cat > "$CONF" << EOF
RUNNER=cursor
TEND_MODE=notify
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
run_job tend
assert_cursor_args "-p --trust /task-orchestrate tend"

echo ""
echo "2c. TEND_MODE default (no setting in conf — go auto)"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
run_job tend
assert_cursor_args "-p --trust /task-orchestrate tend go auto"

echo ""
echo "2d. TEND_MODE=go_auto alias"
cat > "$CONF" << EOF
RUNNER=claude
TEND_MODE=go_auto
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
run_job tend
assert_claude_args "-p tend go auto"

echo ""
echo "2e. invalid TEND_MODE rejected"
cat > "$CONF" << EOF
RUNNER=cursor
TEND_MODE=bogus
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
assert_exit_fail tend "invalid TEND_MODE rejected"

echo ""
echo "2f. session limit on primary falls back to secondary runner"
SESSION_LIMIT_CURSOR="$TMP/cursor-session-limit"
cat > "$SESSION_LIMIT_CURSOR" << EOF
#!/usr/bin/env bash
echo "You've hit your session limit · resets 5:10pm"
exit 1
EOF
chmod +x "$SESSION_LIMIT_CURSOR"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_BIN=$SESSION_LIMIT_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
run_job tend
if [[ -f "$LOG_CLAUDE" ]]; then
  ok "session limit on cursor fell back to claude"
else
  fail "expected claude fallback after cursor session limit"
fi

echo ""
echo "2g. both runners session-limited exits 0 with heartbeat note"
BOTH_LIMIT_CLAUDE="$TMP/claude-session-limit"
cat > "$BOTH_LIMIT_CLAUDE" << EOF
#!/usr/bin/env bash
echo "You've hit your session limit · resets 5:10pm"
exit 1
EOF
chmod +x "$BOTH_LIMIT_CLAUDE"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_BIN=$SESSION_LIMIT_CURSOR
CLAUDE_BIN=$BOTH_LIMIT_CLAUDE
EOF
HEARTBEAT="$WORK/.orchestrate/logs/heartbeat.log"
mkdir -p "$(dirname "$HEARTBEAT")"
rm -f "$HEARTBEAT"
set +e
run_job tend >/dev/null 2>&1
code=$?
set -e
if [[ "$code" -eq 0 ]]; then
  ok "both runners session-limited exit 0"
else
  fail "both runners session-limited should exit 0, got $code"
fi
if grep -qE 'both runners session-limited|deferred' "$HEARTBEAT" 2>/dev/null; then
  ok "heartbeat logs session limit deferral"
else
  fail "heartbeat missing session limit deferral line"
fi

echo ""
echo "2h. connection lost on primary falls back to secondary"
CONN_LOST_CURSOR="$TMP/cursor-conn-lost"
cat > "$CONN_LOST_CURSOR" << EOF
#!/usr/bin/env bash
echo "Connection lost, reconnecting to https://agentn.global.api5.cursor.sh (attempt 1)..."
exit 1
EOF
chmod +x "$CONN_LOST_CURSOR"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_BIN=$CONN_LOST_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
rm -f "$LOG_CLAUDE" "$LOG_CURSOR"
run_job tend
if [[ -f "$LOG_CLAUDE" ]]; then
  ok "connection lost on cursor fell back to claude"
else
  fail "expected claude fallback after cursor connection lost"
fi

echo ""
echo "2i. primary session limit logs reset hint to heartbeat"
HEARTBEAT2="$WORK/.orchestrate/logs/heartbeat.log"
rm -f "$HEARTBEAT2"
cat > "$CONF" << EOF
RUNNER=claude
CURSOR_BIN=$SESSION_LIMIT_CURSOR
CLAUDE_BIN=$BOTH_LIMIT_CLAUDE
EOF
run_job tend >/dev/null 2>&1 || true
if grep -q 'resets 5:10pm' "$HEARTBEAT2" 2>/dev/null; then
  ok "heartbeat includes session limit reset hint"
else
  fail "heartbeat missing session limit reset hint"
fi

echo ""
echo "2j. CURSOR_FALLBACK=never defers when Cursor IDE not running"
HEARTBEAT3="$WORK/.orchestrate/logs/heartbeat.log"
rm -f "$HEARTBEAT3" "$LOG_CLAUDE" "$LOG_CURSOR"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_FALLBACK=never
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
CURSOR_IDE_RUNNING=0 run_job tend >/dev/null 2>&1
if [[ ! -f "$LOG_CLAUDE" && ! -f "$LOG_CURSOR" ]]; then
  ok "CURSOR_FALLBACK=never — no agent invoked when IDE down"
else
  fail "CURSOR_FALLBACK=never should not invoke agents when IDE down"
fi
if grep -q 'Cursor IDE required but not running' "$HEARTBEAT3" 2>/dev/null; then
  ok "heartbeat logs IDE-required deferral"
else
  fail "heartbeat missing IDE-required deferral line"
fi

echo ""
echo "2k. CURSOR_FALLBACK=auto falls back when Cursor IDE not running"
rm -f "$HEARTBEAT3" "$LOG_CLAUDE" "$LOG_CURSOR"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_FALLBACK=auto
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
CURSOR_IDE_RUNNING=0 run_job tend
if [[ -f "$LOG_CLAUDE" ]]; then
  ok "CURSOR_FALLBACK=auto — claude invoked when IDE down"
else
  fail "CURSOR_FALLBACK=auto should fall back to claude when IDE down"
fi

echo ""
echo "2l. exit-0 with no stdout output treated as silent session limit → claude fallback"
SILENT_CURSOR="$TMP/cursor-silent"
HEARTBEAT_SL="$WORK/.orchestrate/logs/heartbeat.log"
cat > "$SILENT_CURSOR" << 'INNEREOF'
#!/usr/bin/env bash
# exits 0 but produces no stdout — simulates new cursor-agent silent session-limit
INNEREOF
chmod +x "$SILENT_CURSOR"
rm -f "$HEARTBEAT_SL" "$LOG_CLAUDE"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_FALLBACK=auto
CURSOR_IDE_RUNNING=1
CURSOR_BIN=$SILENT_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
CURSOR_IDE_RUNNING=1 run_job tend >/dev/null 2>&1 || true
if [[ -f "$LOG_CLAUDE" ]]; then
  ok "silent exit-0 cursor → fell back to claude"
else
  fail "silent exit-0 cursor should trigger fallback to claude"
fi
if grep -q 'session limit' "$HEARTBEAT_SL" 2>/dev/null; then
  ok "heartbeat logs silent session limit"
else
  fail "heartbeat missing silent session limit entry"
fi

echo ""
echo "3. RUNNER=cursor inbox-log-analyzer"
write_conf cursor
run_job inbox-log-analyzer
assert_cursor_args "-p --trust /inbox-log-analyzer"

echo ""
echo "4. RUNNER=claude inbox-log-analyzer"
write_conf claude
run_job inbox-log-analyzer
assert_claude_args "-p /inbox-log-analyzer"

echo ""
echo "5. Error handling"
write_conf bogus
assert_exit_fail tend "unknown RUNNER rejected"

write_conf cursor
assert_exit_fail "not-a-job" "unknown job rejected"

echo ""
echo "5b. run-job.sh syntax self-check"
if bash -n "$RUN_JOB_SRC" 2>/dev/null; then
  ok "ai-toolbox run-job.sh bash syntax valid"
else
  fail "ai-toolbox run-job.sh has bash syntax errors"
fi
if bash -n "$RUN_JOB" 2>/dev/null; then
  ok "installed run-job.sh bash syntax valid"
else
  fail "installed run-job.sh has bash syntax errors"
fi
if grep -q 'bash -n.*BASH_SOURCE' "$RUN_JOB_SRC" 2>/dev/null; then
  ok "run-job.sh self-validates syntax at startup"
else
  fail "run-job.sh missing startup syntax self-check"
fi

echo ""
echo "6. install-launchd.sh source"
INSTALL="/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/install-launchd.sh"
if [[ -f "$INSTALL" ]]; then
  ok "install-launchd.sh exists"
  if bash -n "$INSTALL" 2>/dev/null; then
    ok "install-launchd.sh bash syntax valid"
  else
    fail "install-launchd.sh has bash syntax errors"
  fi
else
  fail "install-launchd.sh missing at $INSTALL"
fi

TEND_PLIST="/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/com.orchestrate.tend.plist"
if grep -q '__RUN_JOB__' "$TEND_PLIST" 2>/dev/null; then
  ok "tend plist template uses __RUN_JOB__ placeholder"
else
  fail "tend plist template missing __RUN_JOB__"
fi

echo ""
echo "7. tend idle skip (no agent when queue empty)"
setup_idle_work() {
  IDLE_WORK="$TMP/idle-work"
  mkdir -p "$IDLE_WORK/.orchestrate/inbox/gated" "$IDLE_WORK/.orchestrate/inbox/processed" \
    "$IDLE_WORK/.orchestrate/logs" "$IDLE_WORK/.orchestrate/bin"
  cp "$PROJECT_ROOT/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh,followup-dedup.sh} \
    "$IDLE_WORK/.orchestrate/bin/"
  chmod +x "$IDLE_WORK/.orchestrate/bin/"*.sh
  cat > "$IDLE_WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — idle-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| test-done | done task | auto | 1 | complete | 2026-01-01T00:00:00Z |
EOF
  cat > "$IDLE_CONF" << EOF
RUNNER=cursor
TEND_MODE="go auto"
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
}
IDLE_CONF="$TMP/idle-agent.conf"
setup_idle_work
rm -f "$LOG_CURSOR" "$LOG_CLAUDE"
if (cd "$IDLE_WORK" && ORCHESTRATE_AGENT_CONF="$IDLE_CONF" bash "$IDLE_WORK/.orchestrate/bin/run-job.sh" tend); then
  if [[ ! -f "$LOG_CURSOR" ]]; then
    ok "tend skips cursor-agent when registry and inbox are idle"
  else
    fail "cursor-agent invoked on idle queue — got: $(cat "$LOG_CURSOR" 2>/dev/null)"
  fi
else
  fail "run-job tend exited non-zero on idle worktree"
fi

if grep -q 'tend go auto — idle' "$IDLE_WORK/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "idle tend appends tend go auto — idle to heartbeat"
else
  fail "heartbeat missing tend go auto — idle line"
fi

echo ""
echo "8. tend_need_action pipefail guard — pending task MUST dispatch agent"
# Regression test: the '| grep | cut || echo 1' pattern inside tend_need_action()
# was unsafe under set -o pipefail. When tend-need-action.sh exits 1 (action needed),
# pipefail marks the pipe failed → '|| echo 1' fires AND cut's output was already
# captured → need="1\n1" → [[ "1\n1" == "1" ]] fails → false idle. Fix: capture raw
# output first, then filter separately.
ACTIVE_WORK="$TMP/active-work"
mkdir -p "$ACTIVE_WORK/.orchestrate/inbox/gated" "$ACTIVE_WORK/.orchestrate/inbox/processed" \
  "$ACTIVE_WORK/.orchestrate/logs" "$ACTIVE_WORK/.orchestrate/bin"
cp "$PROJECT_ROOT/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh,followup-dedup.sh} \
  "$ACTIVE_WORK/.orchestrate/bin/"
chmod +x "$ACTIVE_WORK/.orchestrate/bin/"*.sh
cat > "$ACTIVE_WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — active-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| test-active | pending task | auto | 1 | pending | 2026-01-01T00:00:00Z |
EOF
ACTIVE_CONF="$TMP/active-agent.conf"
LOG_ACTIVE_CURSOR="$TMP/active-cursor.log"
LOG_ACTIVE_CLAUDE="$TMP/active-claude.log"
MOCK_ACTIVE_CURSOR="$TMP/mock-active-cursor.sh"
MOCK_ACTIVE_CLAUDE="$TMP/mock-active-claude.sh"
cat > "$MOCK_ACTIVE_CURSOR" << EOF
#!/usr/bin/env bash
echo "cursor-agent called with: \$*" > "$LOG_ACTIVE_CURSOR"
exit 0
EOF
cat > "$MOCK_ACTIVE_CLAUDE" << EOF
#!/usr/bin/env bash
echo "claude called with: \$*" > "$LOG_ACTIVE_CLAUDE"
exit 0
EOF
chmod +x "$MOCK_ACTIVE_CURSOR" "$MOCK_ACTIVE_CLAUDE"
cat > "$ACTIVE_CONF" << EOF
RUNNER=cursor
TEND_MODE="go auto"
CURSOR_BIN=$MOCK_ACTIVE_CURSOR
CLAUDE_BIN=$MOCK_ACTIVE_CLAUDE
CURSOR_IDE_RUNNING=1
EOF
rm -f "$LOG_ACTIVE_CURSOR" "$LOG_ACTIVE_CLAUDE"
if (cd "$ACTIVE_WORK" && ORCHESTRATE_AGENT_CONF="$ACTIVE_CONF" bash "$ACTIVE_WORK/.orchestrate/bin/run-job.sh" tend); then
  if [[ -f "$LOG_ACTIVE_CURSOR" ]] || [[ -f "$LOG_ACTIVE_CLAUDE" ]]; then
    ok "tend dispatches agent when registry has pending task (pipefail guard works)"
  else
    fail "tend logged idle despite pending task — pipefail bug in tend_need_action() may have regressed"
  fi
else
  fail "run-job tend exited non-zero with pending task"
fi

if ! grep -q 'tend go auto — idle' "$ACTIVE_WORK/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "heartbeat does NOT contain idle when task is pending"
else
  fail "heartbeat shows idle despite pending task — pipefail bug in tend_need_action()"
fi

echo ""
echo "9. cleanup-stale-inbox.sh set -e safety (non-stale inbox file)"
# Regression: [[ cond ]] && continue returns exit 1 when cond is false under set -e,
# killing the script on every inbox file that is not moved (lines 68, 86, 94).
CLEAN_WORK="$TMP/cleanup-work"
mkdir -p "$CLEAN_WORK/.orchestrate/inbox/processed" "$CLEAN_WORK/.orchestrate/logs" \
  "$CLEAN_WORK/.orchestrate/tasks"
cat > "$CLEAN_WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — cleanup-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| test-done | done task | auto | 1 | complete | 2026-01-01T00:00:00Z |
EOF
cat > "$CLEAN_WORK/.orchestrate/inbox/active-item.md" << 'EOF'
# Active inbox item (not stale)

## Goal
Should not crash cleanup-stale-inbox under set -e
EOF
if bash "$PROJECT_ROOT/bin/cleanup-stale-inbox.sh" "$CLEAN_WORK"; then
  ok "cleanup-stale-inbox exits 0 with active non-stale inbox file"
else
  fail "cleanup-stale-inbox exited non-zero — set -e && continue bug may have regressed"
fi

echo ""
echo "10. awaiting_go task — tend is IDLE (notify-only, does NOT gate dispatch)"
# Behavior change e26282d (2026-06-25): awaiting_go is gated/notify-only and no longer
# gates dispatch — tend-need-action.sh excludes it "on purpose" so the launchd cycle does
# not spend AI tokens re-notifying gated tasks every 5 min. When ONLY awaiting_go tasks
# exist (no pending/inbox/awaiting_critic), tend must report idle and NOT invoke an agent.
GATED_WORK="$TMP/gated-work"
mkdir -p "$GATED_WORK/.orchestrate/inbox/gated" "$GATED_WORK/.orchestrate/inbox/processed" \
  "$GATED_WORK/.orchestrate/logs" "$GATED_WORK/.orchestrate/bin"
cp "$PROJECT_ROOT/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh,followup-dedup.sh} \
  "$GATED_WORK/.orchestrate/bin/"
chmod +x "$GATED_WORK/.orchestrate/bin/"*.sh
cat > "$GATED_WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — gated-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| test-gated | gated hello work task | gated | 1 | awaiting_go | 2026-01-01T00:00:00Z |
EOF
GATED_CONF="$TMP/gated-agent.conf"
LOG_GATED_CURSOR="$TMP/gated-cursor.log"
LOG_GATED_CLAUDE="$TMP/gated-claude.log"
MOCK_GATED_CURSOR="$TMP/mock-gated-cursor.sh"
MOCK_GATED_CLAUDE="$TMP/mock-gated-claude.sh"
cat > "$MOCK_GATED_CURSOR" << EOF
#!/usr/bin/env bash
echo "cursor-agent called with: \$*" > "$LOG_GATED_CURSOR"
exit 0
EOF
cat > "$MOCK_GATED_CLAUDE" << EOF
#!/usr/bin/env bash
echo "claude called with: \$*" > "$LOG_GATED_CLAUDE"
exit 0
EOF
chmod +x "$MOCK_GATED_CURSOR" "$MOCK_GATED_CLAUDE"
cat > "$GATED_CONF" << EOF
RUNNER=cursor
TEND_MODE="go auto"
CURSOR_BIN=$MOCK_GATED_CURSOR
CLAUDE_BIN=$MOCK_GATED_CLAUDE
CURSOR_IDE_RUNNING=1
EOF
rm -f "$LOG_GATED_CURSOR" "$LOG_GATED_CLAUDE"
if (cd "$GATED_WORK" && ORCHESTRATE_AGENT_CONF="$GATED_CONF" bash "$GATED_WORK/.orchestrate/bin/run-job.sh" tend); then
  if [[ ! -f "$LOG_GATED_CURSOR" && ! -f "$LOG_GATED_CLAUDE" ]]; then
    ok "tend does NOT dispatch agent when only awaiting_go tasks exist (notify-only, e26282d)"
  else
    fail "agent dispatched for awaiting_go-only registry — e26282d excludes awaiting_go from NEED_ACTION"
  fi
else
  fail "run-job tend exited non-zero with awaiting_go task"
fi

if grep -q 'tend go auto — idle' "$GATED_WORK/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "heartbeat logs idle when only awaiting_go tasks exist (no token spend re-notifying)"
else
  fail "heartbeat missing idle line for awaiting_go-only registry"
fi

echo ""
echo "11. drain-inbox.sh — genuinely-gated file registers as awaiting_go, not pending"
# Guard: a genuinely-gated inbox file (explicit gate_reason OR a risky op) must
# register with status=awaiting_go. If it lands as pending, tend go auto would
# execute it automatically, defeating the gate (the bug B9D8 Hello Work exposed
# on 2026-06-21). Gating is risk-based, not location-based — a bare `mode: gated`
# marker de-gates, so this fixture carries an explicit gate_reason to force a gate.
DRAIN_WORK="$TMP/drain-gated-work"
mkdir -p "$DRAIN_WORK/.orchestrate/inbox/gated" "$DRAIN_WORK/.orchestrate/inbox/processed" \
  "$DRAIN_WORK/.orchestrate/logs"
cat > "$DRAIN_WORK/.orchestrate/inbox/gated/test-gated-task.md" << 'EOF'
mode: gated
gate_reason: explicit human gate — must register awaiting_go, never pending

# Test Gated Task

## Goal
This task should be registered as awaiting_go, never as pending.

## Acceptance Criteria
- Registry row shows status awaiting_go
EOF
if bash "$PROJECT_ROOT/bin/drain-inbox.sh" "$DRAIN_WORK"; then
  if grep -qE '\|\s*awaiting_go\s*\|' "$DRAIN_WORK/.orchestrate/project.md" 2>/dev/null; then
    ok "drain-inbox registers gated/ file as awaiting_go"
  else
    fail "drain-inbox did not set awaiting_go — got: $(grep '^|' "$DRAIN_WORK/.orchestrate/project.md" 2>/dev/null | tail -1 || echo '(no rows)')"
  fi
  if ! grep -qE '\|\s*pending\s*\|' "$DRAIN_WORK/.orchestrate/project.md" 2>/dev/null; then
    ok "drain-inbox did NOT register gated/ file as pending"
  else
    fail "drain-inbox set status=pending for a gated/ file — gated tasks must be awaiting_go"
  fi
else
  fail "drain-inbox.sh exited non-zero on gated inbox file"
fi

if [[ -f "$DRAIN_WORK/.orchestrate/inbox/processed/test-gated-task.md" ]]; then
  ok "drain-inbox moved gated/ file to processed/"
else
  fail "drain-inbox did not move gated/ file to processed/"
fi

if grep -q 'registered (gated)' "$DRAIN_WORK/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "drain-inbox heartbeat contains 'registered (gated)' label"
else
  fail "drain-inbox heartbeat missing 'registered (gated)' — log line format may have changed"
fi

# §10 — pending_task_count and queue drain loop present in run-job.sh
echo ""
echo "── §10 Queue drain loop assertions ──────────────"

if grep -q 'pending_task_count' "$RUN_JOB_SRC" 2>/dev/null; then
  ok "run-job.sh has pending_task_count() function"
else
  fail "run-job.sh missing pending_task_count() — parallel queue drain not wired"
fi

if grep -q 'MAX_TEND_LOOPS' "$RUN_JOB_SRC" 2>/dev/null; then
  ok "run-job.sh has MAX_TEND_LOOPS guard for queue drain loop"
else
  fail "run-job.sh missing MAX_TEND_LOOPS — loop may be unbounded"
fi

if grep -q 'queue drain loop' "$RUN_JOB_SRC" 2>/dev/null; then
  ok "run-job.sh logs queue drain loop iterations"
else
  fail "run-job.sh missing 'queue drain loop' log line"
fi

echo ""
echo "12. tend preflight runs requeue-unblocked.sh WITHOUT 'local outside function' abort"
# Regression (BC0E, 2026-06-25): the requeue-unblocked.sh hook was added to the
# top-level `tend)` case branch as `local requeue_script=...`. `local` is only valid
# inside a function — at top level bash errors "local: can only be used in a function"
# and, under `set -e`, ABORTS run-job.sh before dispatch. Result: every tend cycle
# died silently at that line for ~2 days; pending tasks never executed and rescue
# crash-looped (kick → same abort → kick). This test runs the full preflight (with a
# real requeue-unblocked.sh present so line 393 executes) and asserts:
#   (a) no "can only be used in a function" appears on stderr, and
#   (b) the agent is still dispatched for a pending task.
PREFLIGHT_WORK="$TMP/preflight-work"
mkdir -p "$PREFLIGHT_WORK/.orchestrate/inbox/gated" "$PREFLIGHT_WORK/.orchestrate/inbox/processed" \
  "$PREFLIGHT_WORK/.orchestrate/logs" "$PREFLIGHT_WORK/.orchestrate/bin" "$PREFLIGHT_WORK/.orchestrate/tasks"
cp "$PROJECT_ROOT/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh,followup-dedup.sh} \
  "$PREFLIGHT_WORK/.orchestrate/bin/"
# Copy requeue-unblocked.sh if it exists so the real preflight line is exercised;
# otherwise install a no-op stand-in so the [[ -x ]] guard path is still taken.
if [[ -f "$PROJECT_ROOT/bin/requeue-unblocked.sh" ]]; then
  cp "$PROJECT_ROOT/bin/requeue-unblocked.sh" "$PREFLIGHT_WORK/.orchestrate/bin/"
else
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PREFLIGHT_WORK/.orchestrate/bin/requeue-unblocked.sh"
fi
chmod +x "$PREFLIGHT_WORK/.orchestrate/bin/"*.sh
cat > "$PREFLIGHT_WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — preflight-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| test-pending | pending task | auto | 1 | pending | 2026-01-01T00:00:00Z |
EOF
PREFLIGHT_CONF="$TMP/preflight-agent.conf"
LOG_PRE_CURSOR="$TMP/preflight-cursor.log"
MOCK_PRE_CURSOR="$TMP/mock-preflight-cursor.sh"
cat > "$MOCK_PRE_CURSOR" << EOF
#!/usr/bin/env bash
echo "cursor-agent called with: \$*" > "$LOG_PRE_CURSOR"
exit 0
EOF
chmod +x "$MOCK_PRE_CURSOR"
cat > "$PREFLIGHT_CONF" << EOF
RUNNER=cursor
TEND_MODE="go auto"
CURSOR_BIN=$MOCK_PRE_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
CURSOR_IDE_RUNNING=1
EOF
PREFLIGHT_ERR="$TMP/preflight-stderr.log"
rm -f "$LOG_PRE_CURSOR" "$PREFLIGHT_ERR"
(cd "$PREFLIGHT_WORK" && ORCHESTRATE_AGENT_CONF="$PREFLIGHT_CONF" \
  bash "$PREFLIGHT_WORK/.orchestrate/bin/run-job.sh" tend) >/dev/null 2>"$PREFLIGHT_ERR" || true
if ! grep -q 'can only be used in a function' "$PREFLIGHT_ERR" 2>/dev/null; then
  ok "tend preflight has no 'local outside function' error (BC0E regression)"
else
  fail "run-job.sh aborts with 'local: can only be used in a function' — BC0E bug regressed: $(grep -m1 'can only be used' "$PREFLIGHT_ERR")"
fi
if [[ -f "$LOG_PRE_CURSOR" ]]; then
  ok "tend dispatches agent after requeue preflight (no silent abort)"
else
  fail "agent not dispatched — preflight aborted before dispatch ($(tail -1 "$PREFLIGHT_ERR" 2>/dev/null))"
fi

# Static guard: no `local` may appear in a top-level case branch. Strip function
# bodies (name() { ... }) and assert no `local` survives in the remaining top-level code.
NO_LOCAL_TOPLEVEL="$(awk '
  /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { depth=1; next }
  depth>0 {
    n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m;
    if (depth<=0) depth=0;
    next
  }
  /(^|[[:space:];])local[[:space:]]/ { print NR": "$0 }
' "$RUN_JOB_SRC")"
if [[ -z "$NO_LOCAL_TOPLEVEL" ]]; then
  ok "no 'local' keyword outside a function in run-job.sh source"
else
  fail "'local' used outside a function (will abort under set -e):\n$NO_LOCAL_TOPLEVEL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 68A1: concurrent-tend lock race + registry-corruption regression tests
# ─────────────────────────────────────────────────────────────────────────────
echo "13. lock race + registry off-by-one (task 68A1)"
LOCKTMP="$(mktemp -d "${TMPDIR:-/tmp}/run-job-lock.XXXXXX")"
mkdir -p "$LOCKTMP/.orchestrate"
# Extract the pure-bash funcs under test from the run-job.sh under test; stub log_heartbeat.
FUNCS="$LOCKTMP/funcs.sh"
{
  echo 'log_heartbeat(){ :; }'
  grep -E '^LOCK_STALE_GRACE=' "$RUN_JOB"
  sed -n '/^acquire_tend_lock()/,/^}/p;/^refresh_tend_lock()/,/^}/p;/^cross_task_depends_on_blocked()/,/^}/p;/^mark_pending_tasks_as_running()/,/^}/p;/^repair_registry_rows()/,/^}/p' "$RUN_JOB"
} > "$FUNCS"
LPROJ="$LOCKTMP/.orchestrate/project.md"

# 13a. mark_pending_tasks_as_running stamps last_activity in $7, never the phantom $8
cat > "$LPROJ" << 'PEOF'
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| 20260627-mp01 | pending row | auto | 1 | pending |  |
PEOF
( export ROOT="$LOCKTMP"; source "$FUNCS"; mark_pending_tasks_as_running ) || true
if awk -F'|' '/mp01/{s=$6;a=$7;t=$8;gsub(/ /,"",s);gsub(/ /,"",t);gsub(/^[ ]+|[ ]+$/,"",a); exit !(s=="running" && a ~ /Z$/ && t=="" && NF==8)}' "$LPROJ"; then
  ok "mark_pending stamps last_activity in \$7 (no phantom \$8 — corruption root cause)"
else
  fail "mark_pending off-by-one regressed: $(grep mp01 "$LPROJ")"
fi

# 13b. repair_registry_rows normalizes a malformed phantom-field row to NF==8 + trailing pipe
printf '## Task Registry\n| ID | summary | mode | current_phase | status | last_activity |\n|----|----|----|----|----|----|\n| 20260627-rr01 | corrupt | auto | 1 | running | 2026-06-27T11:00:00Z | 2026-06-27T11:05:00Z \n' > "$LPROJ"
( export ROOT="$LOCKTMP"; source "$FUNCS"; repair_registry_rows ) || true
if awk -F'|' '/rr01/{exit !(NF==8)}' "$LPROJ" && grep -qE '\| 20260627-rr01 \|.*\| running \| 2026-06-27T11:00:00Z \|$' "$LPROJ"; then
  ok "repair_registry_rows drops phantom field, restores trailing pipe (NF==8)"
else
  fail "repair_registry_rows did not normalize malformed row: $(grep rr01 "$LPROJ")"
fi

# acquire_tend_lock helper: returns "ACQUIRED" on stdout iff the lock was taken.
# (acquire calls exit 0 on backoff, so the trailing echo only runs on success.)
acquire_result() { ( export ROOT="$LOCKTMP"; source "$FUNCS"; acquire_tend_lock && echo ACQUIRED ) 2>/dev/null || true; }
LK="$LOCKTMP/.orchestrate/.tend.lock"

# 13c. NEVER steal a lock whose owner PID is alive — even with an ancient mtime
#      (this is the exact race: a 300s launchd cycle barging into a long live cycle)
rm -f "$LK"
sleep 30 & LIVEPID=$!
printf '%s %s\n' "$LIVEPID" "2020-01-01T00:00:00Z" > "$LK"; touch -t 202001010000 "$LK"
if [[ "$(acquire_result)" != *ACQUIRED* ]] && grep -q "^$LIVEPID " "$LK" 2>/dev/null; then
  ok "acquire_tend_lock backs off a LIVE owner regardless of age (race fixed)"
else
  fail "acquire_tend_lock stole a live owner's lock — concurrent-tend race not fixed"
fi
kill "$LIVEPID" 2>/dev/null || true; wait "$LIVEPID" 2>/dev/null || true

# 13d. reclaim a DEAD owner's lock once it is stale (age > LOCK_STALE_GRACE)
sleep 1 & DEADPID=$!; kill "$DEADPID" 2>/dev/null || true; wait "$DEADPID" 2>/dev/null || true
printf '%s %s\n' "$DEADPID" "2020-01-01T00:00:00Z" > "$LK"; touch -t 202001010000 "$LK"
if [[ "$(acquire_result)" == *ACQUIRED* ]]; then
  ok "acquire_tend_lock reclaims a dead+stale owner's lock"
else
  fail "acquire_tend_lock failed to reclaim a dead+stale lock (would deadlock tend)"
fi

# 13e. do NOT reclaim a DEAD owner's lock while still fresh (< grace) — avoids racing a just-started session
printf '%s %s\n' "$DEADPID" "2026-06-27T00:00:00Z" > "$LK"   # fresh mtime (just written)
if [[ "$(acquire_result)" != *ACQUIRED* ]]; then
  ok "acquire_tend_lock waits out the grace window before reclaiming a dead lock"
else
  fail "acquire_tend_lock reclaimed a dead lock before the grace window"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 20260711-inbox-0C7B: invoke_agent AGENT_TIMEOUT_SECS wrapper regression tests
# A hung claude/cursor CLI subprocess previously blocked run-job.sh (and the
# tend lock it holds) forever — see the ECAF stall investigation. invoke_agent
# now backgrounds the call, watches it with a sleep+kill subshell, and uses
# `wait "$pid"` (not a `kill -0` poll loop, which false-positives on an
# already-exited-but-unreaped zombie PID) to detect real completion.
# ─────────────────────────────────────────────────────────────────────────────
echo "14. invoke_agent AGENT_TIMEOUT_SECS wrapper (task 20260711-inbox-0C7B)"
IATMP="$(mktemp -d "${TMPDIR:-/tmp}/run-job-invoke-agent.XXXXXX")"
mkdir -p "$IATMP/.orchestrate/logs"
IA_HEARTBEAT="$IATMP/heartbeat.log"
: > "$IA_HEARTBEAT"
IA_FUNCS="$IATMP/funcs.sh"
{
  echo "log_heartbeat(){ echo \"\$1\" >> '$IA_HEARTBEAT'; }"
  grep -E '^AGENT_TIMEOUT_SECS=' "$RUN_JOB"
  # shell_probe_failed is required by classify_agent_result (20260724-inbox-7A301);
  # without it, an exit-0 fast agent hits "command not found" (falls through to the
  # non-empty-log check by accident of $? != 0, so the assertions still pass, but a
  # spurious error is printed on every run — extract it alongside the others it needs.
  sed -n '/^shell_probe_failed()/,/^}/p;/^classify_agent_result()/,/^}/p;/^session_limit_reset_hint()/,/^}/p;/^invoke_agent()/,/^}/p' "$RUN_JOB"
} > "$IA_FUNCS"

# 14a. hanging binary: killed within the configured window, classified as timeout,
#      with a distinct heartbeat line — not left running past the deadline.
HANG_BIN="$IATMP/hang-agent"
HANG_MARKER="$IATMP/hang-done-marker"
rm -f "$HANG_MARKER"
cat > "$HANG_BIN" << EOF
#!/usr/bin/env bash
sleep 30
touch "$HANG_MARKER"
EOF
chmod +x "$HANG_BIN"
IA_START=$(date +%s)
IA_HANG_OUT="$( export ROOT="$IATMP"; export AGENT_TIMEOUT_SECS=2; source "$IA_FUNCS"; invoke_agent "$HANG_BIN"; echo "AGENT_RESULT=$AGENT_RESULT" )"
IA_ELAPSED=$(( $(date +%s) - IA_START ))
if [[ "$IA_HANG_OUT" == *"AGENT_RESULT=timeout"* ]]; then
  ok "hung agent classified as timeout"
else
  fail "hung agent not classified as timeout — got: $IA_HANG_OUT"
fi
if [[ ! -f "$HANG_MARKER" ]]; then
  ok "hung agent process killed before completing its sleep (marker never written)"
else
  fail "hung agent process was NOT killed — ran to completion despite timeout"
fi
if [[ "$IA_ELAPSED" -lt 15 ]]; then
  ok "timeout enforced within a bounded window (~${IA_ELAPSED}s for a 2s timeout, not the full 30s hang)"
else
  fail "invoke_agent took ${IA_ELAPSED}s — timeout wrapper did not bound the hang"
fi
if grep -q 'timed out after 2s' "$IA_HEARTBEAT"; then
  ok "timeout event logged to heartbeat with elapsed time"
else
  fail "no distinct timeout heartbeat line written: $(cat "$IA_HEARTBEAT")"
fi

# 14b. fast-exiting binary: no regression to the happy path — classified ok,
#      not accidentally caught by the watcher/zombie-PID race.
: > "$IA_HEARTBEAT"
FAST_BIN="$IATMP/fast-agent"
cat > "$FAST_BIN" << 'EOF'
#!/usr/bin/env bash
echo "fast agent output"
exit 0
EOF
chmod +x "$FAST_BIN"
IA_FAST_START=$(date +%s)
IA_FAST_OUT="$( export ROOT="$IATMP"; export AGENT_TIMEOUT_SECS=30; source "$IA_FUNCS"; invoke_agent "$FAST_BIN"; echo "AGENT_RESULT=$AGENT_RESULT" )"
IA_FAST_ELAPSED=$(( $(date +%s) - IA_FAST_START ))
if [[ "$IA_FAST_OUT" == *"AGENT_RESULT=ok"* ]]; then
  ok "fast-exiting agent still classified ok (no regression)"
else
  fail "fast-exiting agent misclassified — got: $IA_FAST_OUT"
fi
if [[ "$IA_FAST_ELAPSED" -lt 5 ]]; then
  ok "fast-exiting agent returns immediately, does not wait for the timeout window (${IA_FAST_ELAPSED}s)"
else
  fail "fast-exiting agent took ${IA_FAST_ELAPSED}s — watcher/wait logic blocked the happy path"
fi
if ! grep -q 'timed out' "$IA_HEARTBEAT"; then
  ok "no spurious timeout heartbeat line on the happy path"
else
  fail "spurious timeout heartbeat line logged for a fast-exiting agent: $(cat "$IA_HEARTBEAT")"
fi

rm -rf "$IATMP"

# ─────────────────────────────────────────────────────────────────────────────
# 20260719-inbox-B6B3: launchd-minimal-PATH regression — node/npm/npx unreachable
# launchd invokes run-job.sh with PATH=/usr/bin:/bin:/usr/sbin:/sbin (it never
# sources ~/.zshrc), so an unpatched script silently degrades Test & Verify
# phases to `confidence: low` because node/npm/npx/tsc can't be found. The fix
# prepends $HOME/.local/bin (where the hermes node install is symlinked in)
# plus the homebrew/usr-local dirs onto PATH near the top of run-job.sh, before
# any agent dispatch. See 20260718-210655-phase2.log for the original symptom.
# ─────────────────────────────────────────────────────────────────────────────
echo "15. launchd-minimal-PATH export makes node/npm/npx reachable (task B6B3)"

PATH_LINE="$(grep -m1 '^export PATH=' "$RUN_JOB_SRC" 2>/dev/null || true)"
if [[ -n "$PATH_LINE" ]]; then
  ok "run-job.sh has an export PATH= line near startup"
else
  fail "run-job.sh missing export PATH= line — launchd-minimal-PATH fix may have regressed"
fi

if [[ "$PATH_LINE" == *'$HOME/.local/bin'* ]]; then
  ok "PATH export includes \$HOME/.local/bin (hermes node install symlink dir)"
else
  fail "PATH export missing \$HOME/.local/bin — node/npm/npx would stay unreachable: $PATH_LINE"
fi

if [[ "$PATH_LINE" == *':$PATH"'* ]]; then
  ok "PATH export prepends (preserves existing \$PATH — operator overrides still win)"
else
  fail "PATH export does not preserve existing \$PATH — may clobber agent.conf overrides: $PATH_LINE"
fi

# Functional check: simulate the exact launchd-minimal PATH, source only the
# extracted export line (not the whole script — avoids invoking real agents),
# and confirm node/npm/npx become reachable afterward. Mirrors how task B6B3
# manually verified the fix.
if [[ -n "$PATH_LINE" ]]; then
  PATH_TEST_OUT="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash -c "
    $PATH_LINE
    command -v node >/dev/null 2>&1 && echo NODE_OK
    command -v npm  >/dev/null 2>&1 && echo NPM_OK
    command -v npx  >/dev/null 2>&1 && echo NPX_OK
  " 2>/dev/null || true)"
  if [[ "$PATH_TEST_OUT" == *NODE_OK* ]]; then
    ok "node reachable after PATH export under simulated launchd-minimal PATH"
  else
    fail "node NOT reachable after PATH export under minimal PATH — regression would silently degrade Test/Verify phases"
  fi
  if [[ "$PATH_TEST_OUT" == *NPM_OK* && "$PATH_TEST_OUT" == *NPX_OK* ]]; then
    ok "npm and npx reachable after PATH export under simulated launchd-minimal PATH"
  else
    fail "npm/npx NOT reachable after PATH export under minimal PATH: $PATH_TEST_OUT"
  fi

  # Sanity control: without the export, minimal PATH must NOT already have node
  # (otherwise this test would pass regardless of the fix — false confidence).
  BARE_OUT="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash -c 'command -v node' 2>/dev/null || true)"
  if [[ -z "$BARE_OUT" ]]; then
    ok "control: node is NOT reachable under bare launchd-minimal PATH (proves the export line does the work)"
  else
    fail "control invalid — node already reachable under bare minimal PATH ($BARE_OUT); this test would not catch a regression"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 20260724-inbox-7A301: shell-capability preflight probe regression tests
# run-job.sh cannot introspect a dispatched agent session's own tool-permission
# grants pre-dispatch — that decision happens inside the session. The observed
# failure mode: a session whose Shell/Bash tool is rejected mid-session still
# exits 0 with some benign text, which the pre-fix classify_agent_result (plain
# "non-empty log = ok") silently classified `ok`, burning a full tend cycle on a
# session that could do nothing. Fix: embed a per-cycle random token in the
# prompt instructing the session to echo it via its own Shell/Bash tool and
# report a fixed confirmation marker; classify_agent_result now treats a missing
# marker on an otherwise-ok-looking log as a distinct `shell_incapable` result,
# routed through the existing CURSOR_FALLBACK fallback/defer logic.
# ─────────────────────────────────────────────────────────────────────────────
#
# Refresh $TMP/mocks/CONF here (not just at script start). Section 13 (lock race,
# task 68A1) deliberately backdates a lock file's mtime to 2020-01-01 inside the
# shared $TMPDIR tree to test stale-lock reclaim — which was observed to make this
# machine's temp-file janitor reap the ORIGINAL $TMP (a sibling dir created at the
# same time) a few seconds later, well before section 16b-16e need to write real
# mock binaries into it. setup_mocks() is idempotent (fresh mktemp -d + mocks), so
# re-running it here is cheap insurance regardless of the janitor's exact trigger.
setup_mocks
echo ""
echo "16. Shell-capability preflight probe (task 20260724-inbox-7A301)"

echo ""
echo "16a. classify_agent_result() unit-level probe checks (mktemp fixtures)"
SPTMP="$(mktemp -d "${TMPDIR:-/tmp}/run-job-shell-probe.XXXXXX")"
SP_FUNCS="$SPTMP/funcs.sh"
sed -n '/^shell_probe_directive()/,/^}/p;/^shell_probe_failed()/,/^}/p;/^classify_agent_result()/,/^}/p' "$RUN_JOB" > "$SP_FUNCS"

SP_TOKEN="probe-token-happy-1234"

# Happy path: confirmation marker for THIS cycle's token present -> ok, not shell_incapable.
SP_OK_LOG="$SPTMP/ok.log"
printf 'some session chatter\nSHELL_PROBE_CONFIRMED: %s\nmore chatter\n' "$SP_TOKEN" > "$SP_OK_LOG"
SP_OK_OUT="$(SHELL_PROBE_TOKEN="$SP_TOKEN" bash -c "source '$SP_FUNCS'; classify_agent_result 0 '$SP_OK_LOG'")"
if [[ "$SP_OK_OUT" == "ok" ]]; then
  ok "confirmation marker present -> classified ok"
else
  fail "expected ok with marker present, got '$SP_OK_OUT'"
fi

# Failure path: exit 0, non-empty log, marker absent -> shell_incapable. This is the
# exact bug the probe exists to catch (previously misclassified ok on log non-emptiness alone).
SP_FAIL_LOG="$SPTMP/fail.log"
printf 'I looked at the task but my Shell tool calls were rejected this session.\n' > "$SP_FAIL_LOG"
SP_FAIL_OUT="$(SHELL_PROBE_TOKEN="$SP_TOKEN" bash -c "source '$SP_FUNCS'; classify_agent_result 0 '$SP_FAIL_LOG'")"
if [[ "$SP_FAIL_OUT" == "shell_incapable" ]]; then
  ok "marker absent on exit-0 non-empty log -> shell_incapable"
else
  fail "expected shell_incapable, got '$SP_FAIL_OUT'"
fi

# A stale token/marker from a previous cycle's log must NOT satisfy this cycle's probe.
SP_STALE_LOG="$SPTMP/stale.log"
printf 'SHELL_PROBE_CONFIRMED: probe-token-OLD-CYCLE\n' > "$SP_STALE_LOG"
SP_STALE_OUT="$(SHELL_PROBE_TOKEN="$SP_TOKEN" bash -c "source '$SP_FUNCS'; classify_agent_result 0 '$SP_STALE_LOG'")"
if [[ "$SP_STALE_OUT" == "shell_incapable" ]]; then
  ok "stale token/marker from a prior cycle does not satisfy this cycle's probe"
else
  fail "stale-token log should be shell_incapable, got '$SP_STALE_OUT'"
fi

# Probe inactive (SHELL_PROBE_TOKEN unset, e.g. the inbox-log-analyzer dispatch path)
# must be a complete no-op — falls through to the pre-existing ok/session_limit logic.
SP_NOPROBE_OUT="$(bash -c "source '$SP_FUNCS'; classify_agent_result 0 '$SP_OK_LOG'")"
if [[ "$SP_NOPROBE_OUT" == "ok" ]]; then
  ok "probe inactive (no SHELL_PROBE_TOKEN) -> unaffected, ok"
else
  fail "probe-inactive path regressed, got '$SP_NOPROBE_OUT'"
fi

# Empty log (silent session-limit pattern, task B6B3-era fix) must stay session_limit,
# not get shadowed by the new shell-incapable check.
SP_EMPTY_LOG="$SPTMP/empty.log"
: > "$SP_EMPTY_LOG"
SP_EMPTY_OUT="$(SHELL_PROBE_TOKEN="$SP_TOKEN" bash -c "source '$SP_FUNCS'; classify_agent_result 0 '$SP_EMPTY_LOG'")"
if [[ "$SP_EMPTY_OUT" == "session_limit" ]]; then
  ok "empty log stays session_limit (not shadowed by the shell probe)"
else
  fail "empty log should be session_limit, got '$SP_EMPTY_OUT'"
fi

# ── 20260731 false-negative fix: file-sentinel + relaxed classifier ──────────────
# Signal (1) — the session wrote the probe MARKER FILE. This is the robust primary
# signal: a fully-capable `claude -p` session that did the whole cycle but dropped the
# SHELL_PROBE_CONFIRMED sentinel from its final summary must NOT be flagged incapable.
SP_FILE_DIR="$SPTMP/probe"
mkdir -p "$SP_FILE_DIR"
: > "$SP_FILE_DIR/$SP_TOKEN"
SP_FILE_LOG="$SPTMP/file.log"
printf 'Some summary text with no confirmation marker at all.\n' > "$SP_FILE_LOG"
SP_FILE_OUT="$(SHELL_PROBE_TOKEN="$SP_TOKEN" SHELL_PROBE_DIR="$SP_FILE_DIR" bash -c "source '$SP_FUNCS'; classify_agent_result 0 '$SP_FILE_LOG'")"
if [[ "$SP_FILE_OUT" == "ok" ]]; then
  ok "probe marker file present (no response marker) -> ok (false-negative fix)"
else
  fail "expected ok with probe file present, got '$SP_FILE_OUT'"
fi

# A marker file for a DIFFERENT (stale) token must not satisfy this cycle.
SP_STALEFILE_DIR="$SPTMP/probe2"
mkdir -p "$SP_STALEFILE_DIR"
: > "$SP_STALEFILE_DIR/some-old-cycle-token"
SP_STALEFILE_OUT="$(SHELL_PROBE_TOKEN="$SP_TOKEN" SHELL_PROBE_DIR="$SP_STALEFILE_DIR" bash -c "source '$SP_FUNCS'; classify_agent_result 0 '$SP_FAIL_LOG'")"
if [[ "$SP_STALEFILE_OUT" == "shell_incapable" ]]; then
  ok "stale-token marker file does not satisfy this cycle's probe"
else
  fail "stale-token marker file should not pass, got '$SP_STALEFILE_OUT'"
fi

# Signal (3) — no file, no response marker, but the log shows the session demonstrably
# RAN the tend cycle and made no shell-failure admission -> capable (defense-in-depth).
SP_WORK_LOG="$SPTMP/work.log"
printf 'Tend cycle complete. Registry queue is now clear; archived to orchestrate-history.\n' > "$SP_WORK_LOG"
SP_WORK_OUT="$(SHELL_PROBE_TOKEN="$SP_TOKEN" SHELL_PROBE_DIR="$SPTMP/does-not-exist" bash -c "source '$SP_FUNCS'; classify_agent_result 0 '$SP_WORK_LOG'")"
if [[ "$SP_WORK_OUT" == "ok" ]]; then
  ok "completed-tend-work evidence (no marker) -> ok (defense-in-depth)"
else
  fail "expected ok from completed-work evidence, got '$SP_WORK_OUT'"
fi

# ...but a shell-FAILURE admission overrides the completion-phrase heuristic: a session
# that claims completion yet admits its Shell tool was rejected stays shell_incapable.
SP_MIXED_LOG="$SPTMP/mixed.log"
printf 'I planned the tend cycle complete list but my Shell/Bash tool calls were rejected; nothing executed.\n' > "$SP_MIXED_LOG"
SP_MIXED_OUT="$(SHELL_PROBE_TOKEN="$SP_TOKEN" SHELL_PROBE_DIR="$SPTMP/does-not-exist" bash -c "source '$SP_FUNCS'; classify_agent_result 0 '$SP_MIXED_LOG'")"
if [[ "$SP_MIXED_OUT" == "shell_incapable" ]]; then
  ok "shell-failure admission overrides completion-phrase heuristic -> shell_incapable"
else
  fail "expected shell_incapable despite completion phrase, got '$SP_MIXED_OUT'"
fi

rm -rf "$SPTMP"

echo ""
echo "16b. shell-incapable primary falls back to a capable secondary runner"
SHELL_INCAPABLE_CURSOR="$TMP/cursor-shell-incapable"
cat > "$SHELL_INCAPABLE_CURSOR" << 'EOF'
#!/usr/bin/env bash
echo "I reviewed the queue but every Shell/Bash tool call this session was rejected, so I could not execute anything."
exit 0
EOF
chmod +x "$SHELL_INCAPABLE_CURSOR"
HEARTBEAT_SP="$WORK/.orchestrate/logs/heartbeat.log"
rm -f "$HEARTBEAT_SP" "$LOG_CURSOR" "$LOG_CLAUDE"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_FALLBACK=auto
CURSOR_IDE_RUNNING=1
CURSOR_BIN=$SHELL_INCAPABLE_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
CURSOR_IDE_RUNNING=1 run_job tend
if [[ -f "$LOG_CLAUDE" ]]; then
  ok "shell-incapable cursor session falls back to claude"
else
  fail "expected claude fallback after cursor shell-incapable session"
fi
if grep -q 'no shell capability' "$HEARTBEAT_SP" 2>/dev/null; then
  ok "heartbeat logs a distinct shell-incapable classification"
else
  fail "heartbeat missing shell-incapable classification line: $(cat "$HEARTBEAT_SP" 2>/dev/null)"
fi

echo ""
echo "16c. both runners shell-incapable defers the cycle (exit 0, not a hard failure)"
SHELL_INCAPABLE_CLAUDE="$TMP/claude-shell-incapable"
cat > "$SHELL_INCAPABLE_CLAUDE" << 'EOF'
#!/usr/bin/env bash
echo "Shell/Bash tool unavailable this session; nothing executed."
exit 0
EOF
chmod +x "$SHELL_INCAPABLE_CLAUDE"
rm -f "$HEARTBEAT_SP" "$LOG_CURSOR" "$LOG_CLAUDE"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_FALLBACK=auto
CURSOR_IDE_RUNNING=1
CURSOR_BIN=$SHELL_INCAPABLE_CURSOR
CLAUDE_BIN=$SHELL_INCAPABLE_CLAUDE
EOF
set +e
CURSOR_IDE_RUNNING=1 run_job tend >/dev/null 2>&1
code=$?
set -e
if [[ "$code" -eq 0 ]]; then
  ok "both runners shell-incapable exits 0 (deferred)"
else
  fail "both runners shell-incapable should exit 0, got $code"
fi
if grep -q 'no shell capability' "$HEARTBEAT_SP" 2>/dev/null; then
  ok "heartbeat logs shell-incapable deferral for both runners"
else
  fail "heartbeat missing shell-incapable deferral for both runners: $(cat "$HEARTBEAT_SP" 2>/dev/null)"
fi

echo ""
echo "16d. CURSOR_FALLBACK=never defers on shell-incapable primary without invoking secondary"
rm -f "$HEARTBEAT_SP" "$LOG_CURSOR" "$LOG_CLAUDE"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_FALLBACK=never
CURSOR_IDE_RUNNING=1
CURSOR_BIN=$SHELL_INCAPABLE_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
set +e
CURSOR_IDE_RUNNING=1 run_job tend >/dev/null 2>&1
code=$?
set -e
if [[ "$code" -eq 0 ]]; then
  ok "CURSOR_FALLBACK=never — shell-incapable primary exits 0"
else
  fail "CURSOR_FALLBACK=never shell-incapable primary should exit 0, got $code"
fi
if [[ ! -f "$LOG_CLAUDE" ]]; then
  ok "CURSOR_FALLBACK=never — secondary not invoked on shell-incapable primary"
else
  fail "CURSOR_FALLBACK=never should not invoke claude when cursor is shell-incapable"
fi
if grep -q 'deferred (CURSOR_FALLBACK=never)' "$HEARTBEAT_SP" 2>/dev/null; then
  ok "heartbeat logs CURSOR_FALLBACK=never shell-incapable deferral"
else
  fail "heartbeat missing CURSOR_FALLBACK=never shell-incapable deferral line: $(cat "$HEARTBEAT_SP" 2>/dev/null)"
fi

echo ""
echo "16e. capable session (probe confirmation present) — no shell-incapable false positive"
rm -f "$HEARTBEAT_SP" "$LOG_CURSOR" "$LOG_CLAUDE"
write_conf cursor
CURSOR_IDE_RUNNING=1 run_job tend
if ! grep -q 'no shell capability' "$WORK/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "capable session (probe confirmed) does not trigger shell-incapable fallback"
else
  fail "false positive: capable session misclassified as shell-incapable"
fi
if [[ ! -f "$LOG_CLAUDE" ]]; then
  ok "capable session — no unnecessary claude fallback invoked"
else
  fail "capable session unexpectedly fell back to claude"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 20260725-inbox-6B7E (tested per follow-up 20260725-inbox-5F3C): log_heartbeat()
# PID attribution. Every line log_heartbeat() writes must carry a trailing
# [pid=$$] tag — the writer's own, stable-for-its-lifetime PID — so a future
# duplicate-execution incident can confirm/rule out two separate run-job.sh
# wrapper processes being alive, purely from heartbeat.log.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "17. log_heartbeat() PID attribution (task 20260725-inbox-6B7E)"
LHTMP="$(mktemp -d "${TMPDIR:-/tmp}/run-job-log-heartbeat.XXXXXX")"
LH_FUNCS="$LHTMP/funcs.sh"
sed -n '/^log_heartbeat()/,/^}/p' "$RUN_JOB_SRC" > "$LH_FUNCS"

# 17a. a single line carries [pid=<writer's own $$>] and keeps the original message.
LH_LOG="$LHTMP/heartbeat.log"
LH_OUT="$(bash -c "HEARTBEAT_LOG='$LH_LOG'; source '$LH_FUNCS'; log_heartbeat 'test message'; echo \$\$")"
if grep -q "\[pid=${LH_OUT}\]" "$LH_LOG" 2>/dev/null; then
  ok "log_heartbeat() suffixes the line with [pid=\$\$] matching the writer's own PID"
else
  fail "log_heartbeat() missing/incorrect [pid=...] suffix (want pid=$LH_OUT) — got: $(cat "$LH_LOG" 2>/dev/null)"
fi
if grep -q 'test message' "$LH_LOG" 2>/dev/null; then
  ok "log_heartbeat() still writes the original message text (pid suffix is purely additive)"
else
  fail "log_heartbeat() message text missing from heartbeat line: $(cat "$LH_LOG" 2>/dev/null)"
fi

# 17b. two separate wrapper processes (simulated as two separate bash -c
# invocations, each with its own real PID) writing to the SAME log must be
# distinguishable — the entire point of the attribution.
LH_LOG2="$LHTMP/heartbeat2.log"
PID_A="$(bash -c "HEARTBEAT_LOG='$LH_LOG2'; source '$LH_FUNCS'; log_heartbeat 'from A'; echo \$\$")"
PID_B="$(bash -c "HEARTBEAT_LOG='$LH_LOG2'; source '$LH_FUNCS'; log_heartbeat 'from B'; echo \$\$")"
if [[ -n "$PID_A" && -n "$PID_B" && "$PID_A" != "$PID_B" ]] \
   && grep -q "\[pid=${PID_A}\]" "$LH_LOG2" && grep -q "\[pid=${PID_B}\]" "$LH_LOG2"; then
  ok "two separate wrapper processes produce two distinct [pid=...] tags in the same log (PID_A=$PID_A, PID_B=$PID_B)"
else
  fail "distinct-process pid attribution failed — PID_A=$PID_A PID_B=$PID_B log: $(cat "$LH_LOG2" 2>/dev/null)"
fi

rm -rf "$LHTMP"

# ─────────────────────────────────────────────────────────────────────────────
# CROSS-2 (20260727-inbox-7D4A): mark_pending_tasks_as_running() must not
# flip a pending row to running (and thus dispatch it) when its task file's
# depends_on: resolves to ANOTHER TASK's registry ID that isn't `complete` yet.
# This is the actual pre-dispatch gate — the exact gap behind the
# 20260727-inbox-1F27 incident (CH-TABLE-SEED-VERIFY dispatched in the same
# cycle as its gated, unapproved CH-TABLE-SEED-IMPL prerequisite).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "18. CROSS-2: cross-task depends_on: excluded from dispatch batch until the"
echo "    referenced task is complete (task 20260727-inbox-7D4A)"
CTTMP="$(mktemp -d "${TMPDIR:-/tmp}/run-job-cross-task.XXXXXX")"
mkdir -p "$CTTMP/.orchestrate/tasks"
CT_FUNCS="$CTTMP/funcs.sh"
{
  echo 'log_heartbeat(){ echo "$1" >> "'"$CTTMP"'/hb.log"; }'
  sed -n '/^cross_task_depends_on_blocked()/,/^}/p;/^mark_pending_tasks_as_running()/,/^}/p' "$RUN_JOB"
} > "$CT_FUNCS"
CTPROJ="$CTTMP/.orchestrate/project.md"
cat > "$CTPROJ" << 'PEOF'
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| 20260727-inbox-BB01 | CROSS-2 blocker (gated, awaiting_go) | gated | 1 | awaiting_go |  |
| 20260727-inbox-BB02 | CROSS-2 blocker (auto, still pending) | auto | 1 | pending |  |
| 20260727-inbox-BB03 | CROSS-2 blocker (auto, complete) | auto | 1 | complete |  |
| 20260727-inbox-DD01 | CROSS-2 dependent — blocked by gated blocker | auto | 1 | pending |  |
| 20260727-inbox-DD02 | CROSS-2 dependent — blocked by pending blocker | auto | 1 | pending |  |
| 20260727-inbox-DD03 | CROSS-2 dependent — blocker already complete | auto | 1 | pending |  |
| 20260727-inbox-DD04 | CROSS-2 dependent — same-file phase-number depends_on | auto | 1 | pending |  |
| 20260727-inbox-DD05 | CROSS-2 dependent — depends_on: none | auto | 1 | pending |  |
PEOF
printf 'id: 20260727-inbox-DD01\ndepends_on: 20260727-inbox-BB01\n' > "$CTTMP/.orchestrate/tasks/20260727-inbox-DD01.md"
printf 'id: 20260727-inbox-DD02\ndepends_on: 20260727-inbox-BB02\n' > "$CTTMP/.orchestrate/tasks/20260727-inbox-DD02.md"
printf 'id: 20260727-inbox-DD03\ndepends_on: 20260727-inbox-BB03\n' > "$CTTMP/.orchestrate/tasks/20260727-inbox-DD03.md"
printf 'id: 20260727-inbox-DD04\ndepends_on: 1\n' > "$CTTMP/.orchestrate/tasks/20260727-inbox-DD04.md"
printf 'id: 20260727-inbox-DD05\ndepends_on: none\n' > "$CTTMP/.orchestrate/tasks/20260727-inbox-DD05.md"

( export ROOT="$CTTMP"; source "$CT_FUNCS"; mark_pending_tasks_as_running ) || true

row_status() {
  awk -F'|' -v id="$1" '$0 ~ ("\\| " id " \\|") { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$6); print $6; exit }' "$CTPROJ"
}

if [[ "$(row_status 20260727-inbox-DD01)" == "pending" ]]; then
  ok "dependent on a GATED/awaiting_go blocker is NOT dispatched (stays pending)"
else
  fail "dependent on a gated blocker was wrongly flipped to running (status: $(row_status 20260727-inbox-DD01))"
fi
if grep -qF "20260727-inbox-DD01" "$CTTMP/hb.log" 2>/dev/null && grep -qF "awaiting_go" "$CTTMP/hb.log" 2>/dev/null && grep -qF "20260727-inbox-BB01" "$CTTMP/hb.log" 2>/dev/null; then
  ok "skip is logged explicitly naming the gated/awaiting_go blocker"
else
  fail "no explicit gated/awaiting_go skip log line found: $(cat "$CTTMP/hb.log" 2>/dev/null)"
fi

if [[ "$(row_status 20260727-inbox-DD02)" == "pending" ]]; then
  ok "dependent on a still-pending (incomplete) blocker is NOT dispatched (stays pending)"
else
  fail "dependent on an incomplete blocker was wrongly flipped to running (status: $(row_status 20260727-inbox-DD02))"
fi
if grep -qF "20260727-inbox-DD02" "$CTTMP/hb.log" 2>/dev/null && grep -qF "20260727-inbox-BB02" "$CTTMP/hb.log" 2>/dev/null; then
  ok "skip is logged for the still-pending blocker case"
else
  fail "no skip log line found for the still-pending blocker case: $(cat "$CTTMP/hb.log" 2>/dev/null)"
fi

if [[ "$(row_status 20260727-inbox-DD03)" == "running" ]]; then
  ok "dependent whose blocker is already complete IS dispatched normally (no false-positive block)"
else
  fail "dependent with a complete blocker was wrongly withheld (status: $(row_status 20260727-inbox-DD03))"
fi

if [[ "$(row_status 20260727-inbox-DD04)" == "running" ]]; then
  ok "same-file phase-number depends_on (\"1\") is NOT mistaken for a cross-task ref — dispatched normally"
else
  fail "same-file phase-number depends_on wrongly blocked dispatch (status: $(row_status 20260727-inbox-DD04))"
fi

if [[ "$(row_status 20260727-inbox-DD05)" == "running" ]]; then
  ok "depends_on: none is dispatched normally (unaffected by the CROSS-2 gate)"
else
  fail "depends_on: none wrongly blocked dispatch (status: $(row_status 20260727-inbox-DD05))"
fi

rm -rf "$CTTMP"

echo ""
echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
