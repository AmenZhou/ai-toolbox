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

# Churn guard: shared re-queue counter + "blocked after 3×" park. Sourced so the
# counter/park logic exists once (also used by requeue-unblocked.sh + rescue.sh).
# CG_ROOT pins the helper to this project root regardless of caller cwd.
CG_ROOT="$ROOT"
if [[ -f "$ROOT/.orchestrate/bin/churn-guard.sh" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT/.orchestrate/bin/churn-guard.sh"
fi

log_heartbeat() {
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
  mkdir -p "$(dirname "$HEARTBEAT_LOG")"
  echo "$line" >>"$HEARTBEAT_LOG"
  echo "$line" >&2
}

# Launchd wrapper holds .tend.lock; tell the agent to skip SKILL.md T-0 so it does
# not self-abort on the wrapper's own lock (root cause of the 2026-06 tend stall).
LOCK_DIRECTIVE="Launchd-managed run: TEND_LOCK_MANAGED=1 is set and .orchestrate/.tend.lock is already held by your run-job.sh wrapper (released on exit). Per SKILL.md T-0, SKIP the lock block entirely — do NOT check lock age and do NOT exit with 'tend already running'. Proceed directly to T-1."

tend_prompt() {
  local base
  case "$TEND_MODE" in
    go\ auto|go_auto) base="/task-orchestrate tend go auto" ;;
    notify|tend|"")   base="/task-orchestrate tend" ;;
    *)
      echo "run-job.sh: unknown TEND_MODE='$TEND_MODE' in $CONF (expected 'go auto' or 'notify')" >&2
      exit 1
      ;;
  esac
  printf '%s\n\n%s' "$base" "$LOCK_DIRECTIVE"
}

tend_prompt_claude() {
  local base
  case "$TEND_MODE" in
    go\ auto|go_auto) base="tend go auto" ;;
    notify|tend|"")   base="tend" ;;
    *)
      echo "run-job.sh: unknown TEND_MODE='$TEND_MODE' in $CONF (expected 'go auto' or 'notify')" >&2
      exit 1
      ;;
  esac
  printf '%s\n\n%s' "$base" "$LOCK_DIRECTIVE"
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

# Invoke one agent binary; routes ALL output to a per-session log so prose never
# pollutes heartbeat.log (which receives only structured [ISO] lines via log_heartbeat).
invoke_agent() {
  local bin="$1"
  shift
  local agent_log
  agent_log="$ROOT/.orchestrate/logs/$(date -u +%Y%m%d-%H%M%S)-agent.log"
  mkdir -p "$(dirname "$agent_log")"
  set +e
  "$bin" "$@" > "$agent_log" 2>&1
  local code="$?"
  set -e
  AGENT_RESULT="$(classify_agent_result "$code" "$agent_log")"
  AGENT_RESET_HINT="$(session_limit_reset_hint "$agent_log")"
  # Keep the session log for post-mortem (do not remove)
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

# RS01: Mark all `pending` registry rows as `running` before agent dispatch so the
# dashboard reflects the correct state immediately (the agent marks them running
# too, but this is faster and prevents the stale-pending flash).
mark_pending_tasks_as_running() {
  local proj="$ROOT/.orchestrate/project.md"
  [[ -f "$proj" ]] || return 0
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  # Registry row schema: | ID | summary | mode | phase | status | last_activity |
  # → awk -F'|' fields: $2=ID  $6=status  $7=last_activity  $8=<empty trailing>.
  # Only well-formed rows (NF==8) are touched: flip status $6 pending→running and
  # stamp last_activity in $7. (Historic bug: wrote $8, appending a phantom field
  # PAST the trailing pipe — the malformed '| running | ts | ts' corruption that
  # then defeated reset_stale_running_tasks. See repair_registry_rows.)
  awk -F'|' -v OFS='|' -v now="$now" '
    /^\|[[:space:]]*[0-9]/ && NF==8 {
      st=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
      if (st=="pending") { $6=" running "; $7=" " now " " }
    }
    { print }
  ' "$proj" > "$tmp" && mv "$tmp" "$proj"
}

# Repair malformed registry rows: a concurrent writer (pre-lock-fix) could append
# a phantom timestamp field PAST the trailing pipe, yielding rows like
# '| ... | running | <last_activity> | <phantom_ts>' with no trailing pipe. Such
# rows defeat reset_stale_running_tasks (its sed expects '| running | ts |') and
# deadlock the registry. This normalizer keeps the 6 real columns ($2..$7) and
# restores the trailing pipe, dropping any phantom field. No-op on valid rows
# (NF==8 with an empty $8). Atomic temp+mv write.
repair_registry_rows() {
  local proj="$ROOT/.orchestrate/project.md"
  [[ -f "$proj" ]] || return 0
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  awk -F'|' '
    /^\|[[:space:]]*[0-9]/ && NF>=8 {
      trailing=$8; gsub(/[[:space:]]/,"",trailing)
      if (NF>8 || trailing!="") {
        line=$1
        for (i=2; i<=7; i++) line=line "|" $i
        print line "|"; next
      }
    }
    { print }
  ' "$proj" > "$tmp" && mv "$tmp" "$proj"
}

# D328 Bug 1: Detect ghost `running` tasks — tasks stuck in running with
# last_activity older than STALE_RUNNING_SECS and no ✓ complete phase in their
# task file — and reset them to needs_human with an auto-reset hint.
STALE_RUNNING_SECS=600  # 10 minutes
reset_stale_running_tasks() {
  local proj="$ROOT/.orchestrate/project.md"
  [[ -f "$proj" ]] || return 0
  local now_epoch
  now_epoch="$(date +%s)"

  while IFS='|' read -r _ task_id _ _ _ status last_activity _; do
    task_id="${task_id// /}"
    status="${status// /}"
    last_activity="${last_activity// /}"
    [[ "$status" == "running" ]] || continue
    [[ -z "$task_id" || "$task_id" == "ID" || "$task_id" =~ ^-+$ ]] && continue

    # Parse last_activity ISO timestamp to epoch
    local la_epoch=0
    if [[ -n "$last_activity" ]]; then
      la_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$last_activity" +%s 2>/dev/null || echo 0)"
    fi
    local age=$(( now_epoch - la_epoch ))
    [[ $age -lt $STALE_RUNNING_SECS ]] && continue

    # Check task file for any ✓ complete phase
    local task_file="$ROOT/.orchestrate/tasks/${task_id}.md"
    if [[ -f "$task_file" ]] && grep -q '✓ complete' "$task_file" 2>/dev/null; then
      continue  # Has progress — not a ghost
    fi

    # Reset to needs_human and inject resolution hint into task file.
    # Atomic temp+mv write (was `sed -i ''` in place — non-atomic, unsafe under a
    # concurrent reader). Match the row by ID ($2) and flip status $6 running→
    # needs_human, stamping last_activity $7.
    #
    # 14C8 (split-brain fix): the detection loop above matches ANY grep-matched stale
    # `running` row (NF-tolerant positional read), but this mutation historically
    # guarded on NF==8. So a phantom-extra-column row (NF>8 — the
    # `| … | running | <last_activity> | <phantom_ts> |` corruption) was DETECTED but
    # never flipped, while the heartbeat below still logged a ghost-reset. That
    # split-brain left the row stuck `running` (T-4 re-queues only `needs_human` rows)
    # and made the heartbeat lie. Fix: accept NF>=8 and self-heal phantom columns in
    # the same pass (collapse to the 6 real columns + restored trailing pipe), and log
    # the ghost-reset heartbeat ONLY when the flip actually happened (awk signals via
    # exit code; a detected-but-unflipped row logs a distinct SKIPPED line instead).
    local hint="Auto-reset: task stuck in running for ${age}s with no phase progress (tend session likely died)"
    local now_iso
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local rs_tmp rs_rc=0
    rs_tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
    awk -F'|' -v OFS='|' -v id="$task_id" -v ts="$now_iso" '
      /^\|[[:space:]]*[0-9]/ && NF>=8 {
        rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
        st=$6;  gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
        if (rid==id && st=="running") {
          $6=" needs_human "; $7=" " ts " "
          if (NF>8) { NF=8; $8="" }   # drop phantom column(s), restore trailing pipe
          flipped=1
        }
      }
      { print }
      END { exit (flipped ? 0 : 2) }
    ' "$proj" > "$rs_tmp" || rs_rc=$?
    if [[ $rs_rc -eq 0 ]]; then
      mv "$rs_tmp" "$proj"
      if [[ -f "$task_file" ]]; then
        # Prepend human_resolution hint to the first incomplete phase block
        sed -i '' "/^### Phase/a\\
human_resolution: ${hint}" "$task_file" 2>/dev/null || true
      fi
      # Churn guard: this ghost-reset is a re-processing of ${task_id}. Bump the
      # shared counter; if it has now churned ${CG_THRESHOLD:-3}× without
      # converging, park it (needs_human + bypass markers) and file an async
      # investigation job instead of letting it loop forever. cg_park_if_churned
      # returns 0 only when it actually parked.
      if type cg_increment >/dev/null 2>&1; then
        cg_increment "$task_id" >/dev/null 2>&1 || true
        if cg_park_if_churned "$task_id" 2>/dev/null; then
          log_heartbeat "run-job — churn-guard parked ${task_id} after ${CG_THRESHOLD:-3} re-processings (ghost-reset path)"
          continue
        fi
      fi
      log_heartbeat "run-job — ghost-reset ${task_id}: running→needs_human (${age}s stale, no ✓ phase)"
    else
      rm -f "$rs_tmp"
      log_heartbeat "run-job — ghost-reset SKIPPED ${task_id}: stale running row did not flip (malformed/raced); awaiting repair_registry_rows"
    fi
  done < <(grep -E '^\|[[:space:]]*[0-9]' "$proj" 2>/dev/null || true)
}

# E721: auto-finalize watchdog. Completion is NOT atomic — a tend/agent session
# can write every phase block to ✓ complete (and possibly archive the task file)
# but die before flipping the registry row running→complete. T-4 re-queues only
# `needs_human`, so such a row sits `running` forever. This bash analog of the
# SKILL Completion sequence reaps those done-but-running rows: flips the row to
# complete, archives to orchestrate-history/ + MANIFEST (no dup if already
# archived), deletes the stale task file. Idempotent. Runs in the tend preflight
# AFTER repair_registry_rows (so malformed rows are normalized first) and BEFORE
# reset_stale_running_tasks (so a finished-but-running ghost is completed, not
# bounced to needs_human). Guard on -x, log on failure (continue tend).
finalize_completed_tasks() {
  local script="$ROOT/.orchestrate/bin/finalize-completed-tasks.sh"
  if [[ -x "$script" ]]; then
    bash "$script" "$ROOT" || log_heartbeat "run-job — finalize-completed-tasks.sh failed (continuing tend)"
  fi
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

# Count only `pending` rows — used as the loop guard in go-auto mode.
# awaiting_go/needs_human/running are not executable by tend go auto.
pending_task_count() {
  local proj="$ROOT/.orchestrate/project.md"
  [[ -f "$proj" ]] || { echo 0; return; }
  awk -F'|' '
    /^\|/ && $2 !~ /^[[:space:]]*ID[[:space:]]*$/ && $2 !~ /^-+$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)
      if ($6 == "pending") n++
    }
    END { print n + 0 }
  ' "$proj"
}

# Acquire the tend lock at the shell level so it is always released on exit,
# regardless of whether the agent session can execute shell commands.
# Sets TEND_LOCK_MANAGED=1 so the SKILL's T-0 skips its own lock logic.
#
# Concurrency model (fixes the 2026-06 concurrent-tend race that corrupted
# project.md): acquisition is atomic via a noclobber exclusive create, and the
# lock records the owning PID. A second launchd cycle that fires while a long
# go-auto drain (up to MAX_TEND_LOOPS agent sessions, easily >300s) is still
# running finds the lock held by a LIVE pid and skips — it never steals a lock
# whose owner is alive, no matter how old the lock is. The old age-only rule
# (steal at >360s) let the 300s launchd cycle barge into a long live cycle, so
# two writers raced on the registry. A lock is now reclaimed only when its owner
# PID is dead (crashed session) AND the lock has aged past LOCK_STALE_GRACE.
# refresh_tend_lock() touches the lock between dispatch sessions so a healthy
# long cycle also stays fresh for rescue.sh / SKILL T-0 mtime checks.
#
# flock vs noclobber (C319 decision): we deliberately keep the `set -o noclobber`
# exclusive-create lock rather than switching to flock(1). Rationale:
#   - macOS ships no `flock` binary (it is util-linux); this lock must run on the
#     dev Macs and under launchd without extra deps, so flock would need a polyfill.
#   - flock's advisory lock is held by an open fd and released when the process
#     exits — it cannot survive across the multiple short-lived agent SESSIONS a
#     single go-auto drain spawns, which is exactly the window we must protect.
#   - The noclobber create is itself atomic, and we add PID-liveness + grace-based
#     reclaim (above), giving the same mutual exclusion plus crash recovery that a
#     bare flock would not. Registry writes are additionally made atomic (temp+mv)
#     and self-healing (repair_registry_rows / rescue normalizer), so a lost lock
#     degrades to a repairable row, never a deadlock. Decision: keep noclobber.
LOCK_STALE_GRACE=120   # seconds a DEAD owner's lock must age before reclaim

acquire_tend_lock() {
  local lock="$ROOT/.orchestrate/.tend.lock"
  TEND_LOCK_FILE="$lock"
  mkdir -p "$(dirname "$lock")"

  while true; do
    # Atomic test-and-set: noclobber makes '>' fail if the file already exists,
    # so only one racer can create it. Content = "<pid> <iso-acquired>".
    if ( set -o noclobber; printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock" ) 2>/dev/null; then
      # shellcheck disable=SC2064
      trap "rm -f '$lock'" EXIT
      export TEND_LOCK_MANAGED=1
      return 0
    fi

    # Lock held — decide whether the owner is alive.
    local owner_pid age
    owner_pid="$(awk 'NR==1{print $1}' "$lock" 2>/dev/null)"
    age=$(( $(date +%s) - $(date -r "$lock" +%s 2>/dev/null || echo 0) ))

    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      # 14C8: a session can wedge WHILE still holding the lock (the owner is
      # alive to `kill -0` but is no longer making progress). The task it was
      # running then sits `running` forever, because the lock-gated ghost reaper
      # in the tend preflight below never runs on any cycle that exits here — the
      # ghost's own lock-holder blocks its reaping. Reap stale `running` ghosts
      # (≥STALE_RUNNING_SECS, no ✓ phase) BEFORE skipping, so a wedged-owner
      # ghost is reset to needs_human + re-queued by T-4 without waiting for
      # rescue.sh to break the lock. reset_stale_running_tasks touches only stale
      # rows (atomic temp+mv) and never touches the lock, so it is safe to run
      # while another (live) session holds it.
      reset_stale_running_tasks
      log_heartbeat "run-job — tend lock held by live pid $owner_pid (${age}s); skipping cycle (reaped stale ghosts first)"
      exit 0
    fi

    # Owner dead/unknown. Only reclaim once the lock has gone stale, to avoid
    # racing a just-started session that has not yet stamped its PID.
    if [[ $age -lt $LOCK_STALE_GRACE ]]; then
      log_heartbeat "run-job — tend lock owner ${owner_pid:-?} not alive but fresh (${age}s); skipping cycle"
      exit 0
    fi

    log_heartbeat "run-job — reclaiming stale lock (owner ${owner_pid:-?} dead, ${age}s old)"
    rm -f "$lock"
    # loop and retry the atomic create
  done
}

# Touch the lock so a long-running healthy cycle is never seen as stale by a
# concurrent launchd cycle, rescue.sh, or SKILL T-0 (all compare mtime age).
refresh_tend_lock() {
  [[ -n "${TEND_LOCK_FILE:-}" && -f "${TEND_LOCK_FILE:-}" ]] && touch "$TEND_LOCK_FILE" 2>/dev/null || true
}

case "$JOB" in
  tend)
    acquire_tend_lock
    # Self-heal any malformed rows left by a pre-lock-fix concurrent writer so the
    # ghost-reset / requeue logic below can act on them (normalizer is a no-op on
    # valid rows). Must run before reset_stale_running_tasks.
    repair_registry_rows
    # E721: reap done-but-running rows (Completion is not atomic) AFTER the row
    # normalizer and BEFORE the stale-running reaper, so a finished-but-running
    # ghost is finalized to `complete` instead of being bounced to needs_human.
    finalize_completed_tasks
    cleanup_stale_inbox
    drain_inbox

    # D328 Bug 1: Detect and reset ghost running tasks. Runs BEFORE the
    # need-action gate (cheap bash, no tokens) so a stale `running` ghost is
    # reset to `needs_human` — and re-queued if it's an auto job — even on a
    # cycle that would otherwise be idle. `running` no longer gates dispatch.
    reset_stale_running_tasks

    # BC0E: auto-requeue needs_human rows when to_clear / requeue_when_exists signals are met
    requeue_script="$ROOT/.orchestrate/bin/requeue-unblocked.sh"
    if [[ -x "$requeue_script" ]]; then
      bash "$requeue_script" "$ROOT" || log_heartbeat "run-job — requeue-unblocked.sh failed (continuing tend)"
    fi

    if ! tend_need_action; then
      log_tend_idle
      exit 0
    fi

    # go-auto: loop until no pending tasks remain or max iterations reached.
    # Each session handles a parallel batch; if tasks remain after a session
    # (e.g. session limit, new inbox items), fire another session immediately
    # rather than waiting 5 min for the next launchd cycle.
    MAX_TEND_LOOPS=5
    tend_loop=0
    cursor_prompt="$(tend_prompt)" || exit 1
    claude_prompt="$(tend_prompt_claude)" || exit 1

    # RS01: mark pending tasks as running before dispatch so dashboard is accurate.
    if [[ "$TEND_MODE" == "go auto" || "$TEND_MODE" == "go_auto" ]]; then
      mark_pending_tasks_as_running
    fi

    refresh_tend_lock
    dispatch "$cursor_prompt" "$claude_prompt"
    tend_loop=1

    if [[ "$TEND_MODE" == "go auto" || "$TEND_MODE" == "go_auto" ]]; then
      while true; do
        refresh_tend_lock   # keep the lock fresh across long multi-session drains
        drain_inbox  # pick up any new inbox items between sessions
        pcount="$(pending_task_count)"
        [[ "$pcount" -eq 0 ]] && break
        if [[ $tend_loop -ge $MAX_TEND_LOOPS ]]; then
          log_heartbeat "run-job — queue drain reached max loops ($MAX_TEND_LOOPS); $pcount task(s) deferred to next cycle"
          break
        fi
        log_heartbeat "run-job — queue drain loop $((tend_loop + 1))/$MAX_TEND_LOOPS ($pcount pending remaining)"
        refresh_tend_lock
        dispatch "$cursor_prompt" "$claude_prompt"
        tend_loop=$(( tend_loop + 1 ))
      done
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
