#!/usr/bin/env bash
# test-run-job.sh — unit tests for .orchestrate/bin/run-job.sh dispatch logic
# Uses mock cursor/claude binaries; does not invoke real agents.
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_JOB_SRC="${RUN_JOB_SRC:-/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/run-job.sh}"
RUN_JOB="${RUN_JOB:-$PROJECT_ROOT/.orchestrate/bin/run-job.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
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

if grep -q 'cleanup_stale_inbox' "$RUN_JOB" && [[ -x "$PROJECT_ROOT/.orchestrate/bin/cleanup-stale-inbox.sh" ]]; then
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
  cp "$PROJECT_ROOT/.orchestrate/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh} \
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
cp "$PROJECT_ROOT/.orchestrate/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh} \
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
if bash "$PROJECT_ROOT/.orchestrate/bin/cleanup-stale-inbox.sh" "$CLEAN_WORK"; then
  ok "cleanup-stale-inbox exits 0 with active non-stale inbox file"
else
  fail "cleanup-stale-inbox exited non-zero — set -e && continue bug may have regressed"
fi

echo ""
echo "10. awaiting_go task — tend MUST dispatch agent (notification gate)"
# Regression guard: after the 2026-06-21 gated fix, tend go auto no longer EXECUTES
# awaiting_go tasks — but it still DISPATCHES the agent (for PushNotification).
# tend-need-action.sh must return NEED_ACTION=1 for awaiting_go registry rows.
GATED_WORK="$TMP/gated-work"
mkdir -p "$GATED_WORK/.orchestrate/inbox/gated" "$GATED_WORK/.orchestrate/inbox/processed" \
  "$GATED_WORK/.orchestrate/logs" "$GATED_WORK/.orchestrate/bin"
cp "$PROJECT_ROOT/.orchestrate/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh} \
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
  if [[ -f "$LOG_GATED_CURSOR" ]] || [[ -f "$LOG_GATED_CLAUDE" ]]; then
    ok "tend dispatches agent when only awaiting_go tasks exist (notification path still active)"
  else
    fail "tend logged idle for awaiting_go task — tend-need-action.sh must flag awaiting_go as NEED_ACTION=1"
  fi
else
  fail "run-job tend exited non-zero with awaiting_go task"
fi

if ! grep -q 'tend go auto — idle' "$GATED_WORK/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "heartbeat does NOT contain idle when task is awaiting_go"
else
  fail "heartbeat shows idle for awaiting_go task — gated task must trigger agent notification"
fi

echo ""
echo "11. drain-inbox.sh — gated/ file registers as awaiting_go, not pending"
# Guard: drain-inbox.sh must register inbox/gated/ files with status=awaiting_go.
# If the status is pending instead, tend go auto would execute the task automatically,
# defeating the gate (the bug that B9D8 Hello Work exposed on 2026-06-21).
DRAIN_WORK="$TMP/drain-gated-work"
mkdir -p "$DRAIN_WORK/.orchestrate/inbox/gated" "$DRAIN_WORK/.orchestrate/inbox/processed" \
  "$DRAIN_WORK/.orchestrate/logs"
cat > "$DRAIN_WORK/.orchestrate/inbox/gated/test-gated-task.md" << 'EOF'
mode: gated

# Test Gated Task

## Goal
This task should be registered as awaiting_go, never as pending.

## Acceptance Criteria
- Registry row shows status awaiting_go
EOF
if bash "$PROJECT_ROOT/.orchestrate/bin/drain-inbox.sh" "$DRAIN_WORK"; then
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

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
