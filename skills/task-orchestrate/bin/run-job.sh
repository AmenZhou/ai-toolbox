#!/usr/bin/env bash
# Dispatch orchestrate launchd jobs to cursor-agent or claude based on .orchestrate/agent.conf
# Intentionally NO --force / --yolo: tend runs every 5 min unattended; inbox is an exec channel.
set -euo pipefail

JOB="${1:?usage: run-job.sh <tend|inbox-log-analyzer>}"

ROOT="$(pwd)"
CONF="${ORCHESTRATE_AGENT_CONF:-$ROOT/.orchestrate/agent.conf}"
HEARTBEAT_LOG="$ROOT/.orchestrate/logs/heartbeat.log"

# Fail fast on syntax errors so launchd does not silently break tend (exit 2).
if ! bash -n "${BASH_SOURCE[0]}" 2>/dev/null; then
  mkdir -p "$(dirname "$HEARTBEAT_LOG")" 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] run-job — script syntax error; reinstall from ai-toolbox" >>"$HEARTBEAT_LOG" 2>/dev/null || true
  echo "run-job.sh: syntax check failed" >&2
  exit 2
fi

RUNNER=cursor
TEND_MODE="${TEND_MODE:-go auto}"
CURSOR_FALLBACK="${CURSOR_FALLBACK:-auto}"
CURSOR_AUTO_OPEN="${CURSOR_AUTO_OPEN:-false}"
CURSOR_BIN="${CURSOR_AGENT_BIN:-$HOME/.local/bin/cursor-agent}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

cursor_ide_running() {
  if [[ -n "${CURSOR_IDE_RUNNING:-}" ]]; then
    [[ "$CURSOR_IDE_RUNNING" == "1" || "$CURSOR_IDE_RUNNING" == "true" ]]
    return
  fi
  pgrep -xq "Cursor"
}

maybe_open_cursor_ide() {
  [[ "$CURSOR_AUTO_OPEN" == "true" ]] || return 0
  if cursor_ide_running; then
    return 0
  fi
  if command -v open >/dev/null 2>&1; then
    open -a Cursor >/dev/null 2>&1 || true
    sleep 2
  fi
}

if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

log_heartbeat() {
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
  mkdir -p "$(dirname "$HEARTBEAT_LOG")"
  echo "$line" >>"$HEARTBEAT_LOG"
  echo "$line" >&2
}

tend_prompt() {
  case "$TEND_MODE" in
    go\ auto|go_auto) printf '%s' "/task-orchestrate tend go auto" ;;
    notify|tend|"")   printf '%s' "/task-orchestrate tend" ;;
    *)
      echo "run-job.sh: unknown TEND_MODE='$TEND_MODE' in $CONF (expected 'go auto' or 'notify')" >&2
      exit 1
      ;;
  esac
}

tend_prompt_claude() {
  case "$TEND_MODE" in
    go\ auto|go_auto) printf '%s' "tend go auto" ;;
    notify|tend|"")   printf '%s' "tend" ;;
    *)
      echo "run-job.sh: unknown TEND_MODE='$TEND_MODE' in $CONF (expected 'go auto' or 'notify')" >&2
      exit 1
      ;;
  esac
}

# cursor-agent requires permissions.deny (array, may be empty) in project cli.json
ensure_cursor_cli() {
  local cli="$ROOT/.cursor/cli.json"
  local sync="$ROOT/scripts/sync-cursor-claude-permissions.sh"
  if [[ ! -f "$cli" && ! -f "$sync" ]]; then
    return 0
  fi
  if python3 -c "import json; d=json.load(open('$cli')); assert isinstance(d.get('permissions',{}).get('deny'), list)" 2>/dev/null; then
    return 0
  fi
  if [[ -f "$sync" ]]; then
    echo "run-job.sh: repairing invalid $cli via sync-cursor-claude-permissions.sh" >&2
    bash "$sync"
    return 0
  fi
  echo "run-job.sh: $cli missing permissions.deny — cursor-agent will fail" >&2
  return 1
}

# Classify agent output: ok | session_limit | connection_lost | error
classify_agent_result() {
  local code="$1"
  local log_file="$2"
  if [[ "$code" -eq 0 ]]; then
    # Exit 0 with no output = silent session-limit pattern in newer agent versions
    [[ -s "$log_file" ]] && { echo ok; return; }
    echo session_limit
    return
  fi
  if grep -qi 'session limit' "$log_file" 2>/dev/null; then
    echo session_limit
    return
  fi
  if grep -qi 'Connection lost' "$log_file" 2>/dev/null; then
    echo connection_lost
    return
  fi
  echo error
}

session_limit_reset_hint() {
  local log_file="$1"
  local hint
  hint="$(grep -oi 'resets [^·]*' "$log_file" 2>/dev/null | head -1 | sed 's/^resets //')"
  if [[ -n "$hint" ]]; then
    printf '%s' "$hint"
  else
    printf 'unknown'
  fi
}

# Invoke one agent binary; prints output, returns classification via stdout path in AGENT_RESULT
invoke_agent() {
  local bin="$1"
  shift
  local agent_log
  agent_log="$(mktemp "${TMPDIR:-/tmp}/run-job-agent.XXXXXX")"
  set +e
  "$bin" "$@" 2>&1 | tee "$agent_log"
  local code="${PIPESTATUS[0]}"
  set -e
  AGENT_RESULT="$(classify_agent_result "$code" "$agent_log")"
  AGENT_RESET_HINT="$(session_limit_reset_hint "$agent_log")"
  rm -f "$agent_log"
}

run_with_fallback() {
  local primary="$1"
  local cursor_prompt="$2"
  local claude_prompt="$3"
  local secondary
  secondary="$([[ "$primary" == cursor ]] && echo claude || echo cursor)"

  if [[ "$primary" == cursor ]]; then
    maybe_open_cursor_ide
    if ! ensure_cursor_cli; then
      if [[ "$CURSOR_FALLBACK" == "never" ]]; then
        log_heartbeat "run-job — cursor cli.json invalid; tend deferred (CURSOR_FALLBACK=never)"
        return 0
      fi
      log_heartbeat "run-job — cursor cli.json invalid; falling back to claude"
      primary=claude
      secondary=cursor
    elif ! cursor_ide_running; then
      if [[ "$CURSOR_FALLBACK" == "never" ]]; then
        log_heartbeat "run-job — Cursor IDE required but not running; tend deferred"
        return 0
      fi
      log_heartbeat "run-job — Cursor not running; falling back to claude"
      primary=claude
      secondary=cursor
    fi
  fi

  if [[ "$primary" == cursor ]]; then
    invoke_agent "$CURSOR_BIN" -p --trust "$cursor_prompt"
  else
    invoke_agent "$CLAUDE_BIN" -p "$claude_prompt"
  fi

  case "$AGENT_RESULT" in
    ok) return 0 ;;
    session_limit)
      log_heartbeat "run-job — $primary hit session limit (resets ${AGENT_RESET_HINT}); trying $secondary"
      ;;
    connection_lost)
      log_heartbeat "run-job — $primary connection lost; trying $secondary"
      ;;
    *)
      return 1
      ;;
  esac

  if [[ "$secondary" == cursor ]]; then
    maybe_open_cursor_ide
    if ! ensure_cursor_cli || ! cursor_ide_running; then
      log_heartbeat "run-job — $secondary unavailable; inbox/tend deferred"
      return 0
    fi
    invoke_agent "$CURSOR_BIN" -p --trust "$cursor_prompt"
  else
    invoke_agent "$CLAUDE_BIN" -p "$claude_prompt"
  fi

  case "$AGENT_RESULT" in
    ok) return 0 ;;
    session_limit)
      log_heartbeat "run-job — both runners session-limited (resets ${AGENT_RESET_HINT}); inbox queued until reset"
      return 0
      ;;
    connection_lost)
      log_heartbeat "run-job — both runners connection-lost; will retry next cycle"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

dispatch() {
  local cursor_prompt="$1"
  local claude_prompt="$2"
  case "$RUNNER" in
    cursor) run_with_fallback cursor "$cursor_prompt" "$claude_prompt" ;;
    claude) run_with_fallback claude "$cursor_prompt" "$claude_prompt" ;;
    *)
      echo "run-job.sh: unknown RUNNER='$RUNNER' in $CONF (expected cursor or claude)" >&2
      exit 1
      ;;
  esac
}

cleanup_stale_inbox() {
  local script="$ROOT/.orchestrate/bin/cleanup-stale-inbox.sh"
  if [[ -x "$script" ]]; then
    bash "$script" "$ROOT" || log_heartbeat "run-job — cleanup-stale-inbox.sh failed (continuing tend)"
  fi
}

drain_inbox() {
  local script="$ROOT/.orchestrate/bin/drain-inbox.sh"
  if [[ -x "$script" ]]; then
    bash "$script" "$ROOT" || log_heartbeat "run-job — drain-inbox.sh failed (continuing tend)"
  fi
}

tend_need_action() {
  local script="$ROOT/.orchestrate/bin/tend-need-action.sh"
  local need=1
  if [[ -x "$script" ]]; then
    # Capture raw output first (ignoring exit code with || true) before filtering.
    # The inline pipeline '| grep | cut || echo 1' misfires under set -o pipefail:
    # when the script exits 1 (action needed), pipefail marks the pipe failed so
    # '|| echo 1' fires AND cut's output is already captured, yielding need="1\n1"
    # which fails the '== "1"' check — causing false idle reports.
    local raw
    raw="$(bash "$script" "$ROOT" 2>/dev/null)" || true
    need="$(printf '%s\n' "$raw" | grep '^NEED_ACTION=' | cut -d= -f2)" || true
    [[ -z "$need" ]] && need=1
  fi
  [[ "$need" == "1" ]]
}

log_tend_idle() {
  case "$TEND_MODE" in
    go\ auto|go_auto) log_heartbeat "tend go auto — idle" ;;
    *)                log_heartbeat "tend — idle" ;;
  esac
}

# Acquire the tend lock at the shell level so it is always released on exit,
# regardless of whether the agent session can execute shell commands.
# Sets TEND_LOCK_MANAGED=1 so the SKILL's T-0 skips its own lock logic.
acquire_tend_lock() {
  local lock="$ROOT/.orchestrate/.tend.lock"
  if [[ -f "$lock" ]]; then
    local age
    age=$(( $(date +%s) - $(date -r "$lock" +%s 2>/dev/null || echo 0) ))
    if [[ $age -lt 360 ]]; then
      log_heartbeat "run-job — tend lock held (${age}s); skipping cycle"
      exit 0
    fi
    log_heartbeat "run-job — clearing stale lock (${age}s old)"
    rm -f "$lock"
  fi
  mkdir -p "$(dirname "$lock")"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$lock"
  # shellcheck disable=SC2064
  trap "rm -f '$lock'" EXIT
  export TEND_LOCK_MANAGED=1
}

case "$JOB" in
  tend)
    acquire_tend_lock
    cleanup_stale_inbox
    drain_inbox
    if tend_need_action; then
      cursor_prompt="$(tend_prompt)" || exit 1
      claude_prompt="$(tend_prompt_claude)" || exit 1
      dispatch "$cursor_prompt" "$claude_prompt"
    else
      log_tend_idle
      exit 0
    fi
    ;;
  inbox-log-analyzer)
    dispatch "/inbox-log-analyzer" "/inbox-log-analyzer"
    ;;
  *)
    echo "run-job.sh: unknown job '$JOB' (expected tend or inbox-log-analyzer)" >&2
    exit 1
    ;;
esac
