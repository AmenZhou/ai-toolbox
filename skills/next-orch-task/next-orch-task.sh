#!/bin/bash
# next-orch-task — Recommend the next executable task from orchestrate registry
# Usage: next-orch-task [--root ROOT] [--verbose] [--json] [--limit N] [--include-gated]

set -uo pipefail

# Parse options
ROOT="${ORCHESTRATE_ROOT:-.}"
VERBOSE=0
JSON_OUTPUT=0
LIMIT=1
INCLUDE_GATED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --include-gated)
      INCLUDE_GATED=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Default root if not specified
if [[ "$ROOT" == "." && ! -d "./.orchestrate" ]]; then
  ROOT="/Users/haimengzhou/apps/ai-console"
fi

REGISTRY="$ROOT/.orchestrate/project.md"
TASKS_DIR="$ROOT/.orchestrate/tasks"
CHECK_DEPENDS="$ROOT/.orchestrate/bin/check-depends-on.sh"

# Validate registry exists
if [[ ! -f "$REGISTRY" ]]; then
  echo "Error: Registry not found at $REGISTRY" >&2
  exit 2
fi

# Helper: Format timestamp age
format_age() {
  local timestamp="$1"
  local now=$(date +%s)
  local ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo "$now")
  local age=$((now - ts))
  
  if [[ $age -lt 60 ]]; then
    echo "${age}s ago"
  elif [[ $age -lt 3600 ]]; then
    echo "$((age / 60))m ago"
  elif [[ $age -lt 86400 ]]; then
    echo "$((age / 3600))h ago"
  else
    echo "$((age / 86400))d ago"
  fi
}

# Count tasks by status using AWK
count_by_status() {
  local status="$1"
  awk -F'|' -v s="$status" '$0 ~ /^\|[[:space:]]*[0-9]/ {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6);
    if ($6 == s) count++
  } END { print count + 0 }' "$REGISTRY"
}

# Extract all pending candidates and check them
# Returns lines formatted as: id|summary|mode|phase|activity
declare -a auto_candidates
declare -a gated_candidates
declare -a blocked_tasks

# Use AWK to extract registry rows and then process each one
while IFS='|' read -r _ id summary mode phase status activity _; do
  # Trim whitespace
  id=$(echo "$id" | xargs)
  summary=$(echo "$summary" | xargs)
  mode=$(echo "$mode" | xargs)
  phase=$(echo "$phase" | xargs)
  status=$(echo "$status" | xargs)
  activity=$(echo "$activity" | xargs)
  
  # Skip if any field is empty (header/malformed rows)
  [[ -z "$id" || -z "$status" ]] && continue
  
  # Skip non-pending tasks
  if [[ "$status" != "pending" ]]; then
    continue
  fi
  
  # Check task file exists
  task_file="$TASKS_DIR/$id.md"
  if [[ ! -f "$task_file" ]]; then
    [[ $VERBOSE -eq 1 ]] && echo "# Skipping $id: task file missing" >&2
    continue
  fi
  
  # Check cross-task dependencies
  if [[ -x "$CHECK_DEPENDS" ]]; then
    block_info=$("$CHECK_DEPENDS" "$ROOT" "$id" 2>/dev/null || true)
    if [[ -n "$block_info" ]]; then
      blocked_tasks+=("$id|$summary|$mode|$phase|$activity|$block_info")
      [[ $VERBOSE -eq 1 ]] && echo "# Skipping $id: blocked by $block_info" >&2
      continue
    fi
  fi
  
  # This is a valid candidate
  if [[ "$mode" == "auto" ]]; then
    auto_candidates+=("$id|$summary|$mode|$phase|$activity")
  else
    gated_candidates+=("$id|$summary|$mode|$phase|$activity")
  fi
done < <(awk -F'|' 'NF==8 && /^\|[[:space:]]*[0-9]/ { print }' "$REGISTRY")

# Sort and select recommendations
recommended=()
if [[ ${#auto_candidates[@]} -gt 0 ]]; then
  # Sort auto candidates by phase, then activity, then id
  IFS=$'\n' sorted_auto=($(for c in "${auto_candidates[@]}"; do echo "$c"; done | sort -t'|' -k4n,4 -k5,5 -k1,1))
  recommended=("${sorted_auto[@]:0:$LIMIT}")
elif [[ ${#gated_candidates[@]} -gt 0 && $INCLUDE_GATED -eq 1 ]]; then
  # Sort gated candidates by phase, then activity, then id
  IFS=$'\n' sorted_gated=($(for c in "${gated_candidates[@]}"; do echo "$c"; done | sort -t'|' -k4n,4 -k5,5 -k1,1))
  recommended=("${sorted_gated[@]:0:$LIMIT}")
fi

# Collect registry statistics
total=$(awk -F'|' 'NF==8 && /^\|[[:space:]]*[0-9]/ { count++ } END { print count + 0 }' "$REGISTRY")
complete=$(count_by_status "complete")
running=$(count_by_status "running")
pending=$(count_by_status "pending")
needs_human=$(count_by_status "needs_human")
awaiting_go=$(count_by_status "awaiting_go")
blocked=$(count_by_status "blocked")

# Output result
if [[ ${#recommended[@]} -gt 0 ]]; then
  if [[ $JSON_OUTPUT -eq 1 ]]; then
    # JSON output
    echo "{"
    echo "  \"success\": true,"
    echo "  \"recommended\": ["
    for i in "${!recommended[@]}"; do
      IFS='|' read -r id summary mode phase activity <<< "${recommended[$i]}"
      echo "    {\"id\": \"$id\", \"mode\": \"$mode\", \"phase\": $phase}"
      [[ $((i + 1)) -lt ${#recommended[@]} ]] && echo ","
    done
    echo "  ],"
    echo "  \"registry_status\": {"
    echo "    \"total\": $total, \"complete\": $complete, \"pending\": $pending,"
    echo "    \"needs_human\": $needs_human, \"awaiting_go\": $awaiting_go"
    echo "  }"
    echo "}"
  else
    # Human-readable output
    echo "RECOMMENDED TASK"
    echo "════════════════════════════════════════"
    echo ""
    
    IFS='|' read -r id summary mode phase activity <<< "${recommended[0]}"
    echo "ID:       $id"
    echo "Title:    $summary"
    echo "Mode:     $mode"
    echo "Phase:    $phase / (unknown)"
    echo "Status:   pending"
    echo "Posted:   $activity ($(format_age "$activity"))"
    echo ""
    echo "RATIONALE"
    echo "─────────"
    echo "✓ Status is pending (ready to dispatch)"
    echo "✓ No cross-task dependencies or dependencies met"
    echo "✓ Task file exists and is readable"
    echo "✓ Mode is $mode (can dispatch)"
    echo "✓ Highest priority in queue"
    echo ""
    echo "REGISTRY STATUS"
    echo "───────────────"
    echo "Total tasks: $total"
    echo "  ├─ complete: $complete"
    echo "  ├─ running: $running"
    echo "  ├─ pending: $pending"
    echo "  ├─ needs_human: $needs_human"
    echo "  ├─ awaiting_go: $awaiting_go"
    echo "  └─ blocked: $blocked"
  fi
  exit 0
else
  # No recommendations
  if [[ $JSON_OUTPUT -eq 1 ]]; then
    echo "{\"success\": false, \"reason\": \"No executable tasks\"}"
  else
    echo "NO EXECUTABLE TASKS"
    echo "═══════════════════"
    echo ""
    echo "All pending tasks are blocked by unmet dependencies."
    echo ""
    echo "PENDING SUMMARY"
    echo "───────────────"
    echo "Total pending tasks: $pending"
    echo "- Blocked by dependencies: ${#blocked_tasks[@]}"
    echo "- Auto-dispatchable: 0"
    echo "- Gated (awaiting approval): ${#gated_candidates[@]}"
    echo ""
    
    if [[ ${#blocked_tasks[@]} -gt 0 ]]; then
      echo "BLOCKED TASKS"
      echo "─────────────"
      for bt in "${blocked_tasks[@]}"; do
        IFS='|' read -r id summary mode phase activity dep_info <<< "$bt"
        dep_id="${dep_info%%$'\t'*}"
        dep_status="${dep_info#*$'\t'}"
        echo "Task: $id ($summary)"
        echo "  Blocked by: $dep_id (status: $dep_status)"
        echo ""
      done
    fi
    
    echo "REGISTRY STATUS"
    echo "───────────────"
    echo "Total tasks: $total"
    echo "  ├─ complete: $complete"
    echo "  ├─ running: $running"
    echo "  ├─ pending: $pending"
    echo "  ├─ needs_human: $needs_human"
    echo "  ├─ awaiting_go: $awaiting_go"
    echo "  └─ blocked: $blocked"
  fi
  exit 1
fi
