#!/usr/bin/env bash
# Kube PreToolUse hook — tiered kubectl/helm gate.
# - Auto-allow: read-only + dry-run/diff/template (no human)
# - Block live mutating: agent remediates first (dry-run/diff/review script), human only for live apply
#
# Installed: ~/.claude/hooks/kube-pretooluse.sh (symlink from ai-console)

set -uo pipefail

INPUT=$(cat)

COMMAND=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('command') or (d.get('tool_input') or {}).get('command') or '')
except Exception:
    print('')
" 2>/dev/null)

# Not kubectl / helm — passthrough check.
# Uses a temp Python file to avoid bash double-quote / Python regex escaping conflicts.
_kube_check_py="$(mktemp /tmp/.kube-check.XXXXXX.py 2>/dev/null || echo "/tmp/.kube-check-$$.py")"
cat > "$_kube_check_py" << 'PYEOF'
import re, sys
cmd = sys.argv[1] if len(sys.argv) > 1 else ''
# Strip heredoc bodies — prevents false positives from kubectl/helm words inside << EOF ... EOF content
cmd = re.sub(r"<<[-]?\s*\S*?(\w+)\S*\n.*?\n\1\b", '', cmd, flags=re.DOTALL)
# Strip quoted strings
stripped = re.sub(r'"[^"\\]*(?:\\.[^"\\]*)*"', '', cmd)
stripped = re.sub(r"'[^']*'", '', stripped)
# Split on all shell command separators (pipes, logic ops, semicolons, newlines)
for seg in re.split(r'\|\||\||&&|;|\n', stripped):
    seg = seg.strip()
    if re.match(r'(?:sudo\s+)?(?:/\S+/)*(kubectl|helm)(\s|$)', seg):
        sys.exit(0)
sys.exit(1)
PYEOF
# FDAB: known cluster-mutating wrapper scripts internally shell out to
# kubectl/clickhouse-client/etc., so their literal command text contains no
# `kubectl`/`helm` segment and would otherwise pass straight through below with
# no review. Detect them by name and let them fall through to the tiered gate:
# a `--dry-run` invocation is auto-allowed by Tier 2, anything else fails closed
# at the catch-all block_live() at the end of this file.
CLUSTER_WRAPPER_RE='(provision_ch_tables|apply_round_config|apply_[A-Za-z0-9_]+_config|provision_[A-Za-z0-9_]+_tables)\.sh'
IS_CLUSTER_WRAPPER=0
if printf '%s' "$COMMAND" | grep -qE "$CLUSTER_WRAPPER_RE"; then
  IS_CLUSTER_WRAPPER=1
fi

if ! python3 "$_kube_check_py" "$COMMAND" 2>/dev/null; then
  rm -f "$_kube_check_py"
  # Literal command is not kubectl/helm. Pass through UNLESS it is a known
  # cluster wrapper script (handled by the tiered gate below).
  [ "$IS_CLUSTER_WRAPPER" -eq 0 ] && exit 0
else
  rm -f "$_kube_check_py"
fi

# FIX-1: normalize leading global flags so a flag before the verb (e.g.
# `kubectl -n ads get pods`) doesn't defeat the anchored tier regexes. Strip ONLY
# a small explicit allowlist of value-taking global flags immediately after
# `kubectl`; anything else stays put and still falls to the conservative
# catch-all (fail closed). Used only for tier VERB matching below — block_live()
# still logs the original $COMMAND.
NORM_COMMAND=$(python3 -c '
import re, sys
cmd = sys.argv[1]
prev = None
while prev != cmd:
    prev = cmd
    cmd = re.sub(r"(\bkubectl)\s+(-n|--namespace|--context|--kubeconfig|-v|--v)(=\S+|\s+\S+)", r"\1", cmd, count=1)
print(cmd)
' "$COMMAND" 2>/dev/null)
[ -z "$NORM_COMMAND" ] && NORM_COMMAND="$COMMAND"

TMP=""
REVIEW_ID_OUT=""

ensure_review_script() {
  [ -n "$TMP" ] && [ -f "$TMP" ] && return 0
  local tmp_base
  tmp_base="$(mktemp /tmp/kube-cmd.XXXXXX)" || return 1
  TMP="${tmp_base}.sh"
  mv "$tmp_base" "$TMP"
  chmod 700 "$TMP"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Intercepted Kubernetes command — review before LIVE cluster apply\n'
    printf '# Safe previews (dry-run/diff) are auto-allowed; this script is for human-approved live changes.\n'
    printf '%s\n' "$COMMAND"
  } >"$TMP"

  # Add token-write code to the script
  local review_id project_root approval_token_path
  review_id="cmd-$(printf '%s' "$COMMAND" | tr -s '[:space:]' ' ' | sha256sum 2>/dev/null | cut -c1-16 || printf '%s' "$COMMAND" | md5sum | cut -c1-16)"
  project_root="$(resolve_project_root)"
  approval_token_path="$project_root/.orchestrate/kube-reviews/approved/$review_id.token"

  cat >> "$TMP" << 'EOF'

# Auto-approve this review when the mutation script runs successfully
if [ $? -eq 0 ]; then
  mkdir -p "$(dirname "'"$approval_token_path"'")"
  echo '{"review_id":"'"$review_id"'","approved_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","approved_by":"manual-script"}' > "'"$approval_token_path"'" 2>/dev/null || true
fi
EOF
}

resolve_project_root() {
  if [ -n "${AI_CONSOLE_ROOT:-}" ] && [ -d "${AI_CONSOLE_ROOT}/.orchestrate" ]; then
    printf '%s\n' "$AI_CONSOLE_ROOT"
    return 0
  fi
  local hook="$0"
  if [ -L "$hook" ]; then
    hook="$(readlink "$hook" 2>/dev/null || echo "$hook")"
    case "$hook" in /*) ;; *) hook="$(cd "$(dirname "$0")" && pwd)/$(basename "$hook")" ;; esac
  else
    hook="$(cd "$(dirname "$hook")" && pwd)/$(basename "$hook")"
  fi
  local candidate
  candidate="$(dirname "$(dirname "$(dirname "$hook")")")"
  if [ -d "$candidate/.orchestrate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ -d "$(pwd)/.orchestrate" ]; then
    printf '%s\n' "$(pwd)"
  fi
}

check_agent_approved() {
  local project_root review_id
  project_root="$(resolve_project_root)"
  [ -n "$project_root" ] || return 1

  # Compute stable ID for this command
  review_id="cmd-$(printf '%s' "$COMMAND" | tr -s '[:space:]' ' ' | sha256sum 2>/dev/null | cut -c1-16 || printf '%s' "$COMMAND" | md5sum | cut -c1-16)"

  local token="$project_root/.orchestrate/kube-reviews/approved/$review_id.token"
  if [ -f "$token" ]; then
    # Read risk level from token
    local risk
    risk="$(python3 -c "import json,sys; d=json.load(open('$token')); print(d.get('risk_assessment','unknown'))" 2>/dev/null || echo 'unknown')"
    printf '✓ kube hook: agent-approved (risk=%s) — auto-run allowed\n' "$risk" >&2
    return 0
  fi
  return 1
}

write_kube_review_queue() {
  local project_root review_id queue_dir created_at
  project_root="$(resolve_project_root)"
  [ -n "$project_root" ] || return 0
  [ -d "$project_root/.orchestrate" ] || return 0

  review_id="cmd-$(printf '%s' "$COMMAND" | tr -s '[:space:]' ' ' | sha256sum 2>/dev/null | cut -c1-16 || printf '%s' "$COMMAND" | md5sum | cut -c1-16)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  queue_dir="$project_root/.orchestrate/kube-reviews/pending"
  mkdir -p "$queue_dir"

  local pending_file="$queue_dir/$review_id.json"
  if [ ! -f "$pending_file" ]; then
    python3 -c "
import json, sys
entry = {
    'id': sys.argv[1],
    'created_at': sys.argv[2],
    'command': sys.argv[3],
    'script_path': sys.argv[4],
    'tier': 'live_mutating',
    'project_root': sys.argv[5],
    'status': 'pending',
}
print(json.dumps(entry, indent=2))
" "$review_id" "$created_at" "$COMMAND" "${TMP:-none}" "$project_root" >"$pending_file"
  fi

  REVIEW_ID_OUT="$review_id"
  printf 'Review ID: %s\n' "$review_id"
  printf 'Monitor: .orchestrate/kube-reviews/pending/%s.json\n' "$review_id"
}

allow() {
  local reason="${1:-allowed}"
  printf '✓ kube hook: %s\n' "$reason" >&2
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":sys.argv[1]}}))' "$reason"
  exit 0
}

block_live() {
  # Check for prior agent approval (stable hash ID)
  if check_agent_approved; then
    allow "agent-approved live command"
  fi

  ensure_review_script || {
    printf '🚫 kube hook: could not create review script\n' >&2
    python3 -c 'import json; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"could not create review script"}}))'
    exit 2
  }
  write_kube_review_queue

  local rid="${REVIEW_ID_OUT:-unknown}"
  local msg review_script_path="$TMP"
  msg=$(printf '⏸ kube hook: live mutating command queued for review\nReview ID: %s\nMonitor: .orchestrate/kube-reviews/pending/%s.json\n\nStep 1: Review the script at %s\nStep 2: Run it to approve and apply the mutation:\n  bash %s\nStep 3: Retry your original command — it will auto-allow once the script has run' "$rid" "$rid" "$review_script_path" "$review_script_path")
  printf '%s\n' "$msg" >&2
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":sys.argv[1]}}))' "$msg"
  exit 2
}

# ── Tier 1: read-only kubectl / helm ─────────────────────────────────────────
if printf '%s' "$NORM_COMMAND" | grep -qE 'kubectl[[:space:]]+(get|describe|logs|top|explain|api-resources|api-versions|cluster-info|auth[[:space:]]+can-i|config[[:space:]]+(view|get-contexts|current-context)|diff|rollout[[:space:]]+(status|history))([[:space:]]|$)'; then
  allow "read-only kubectl allowed"
fi
if printf '%s' "$NORM_COMMAND" | grep -qE 'helm[[:space:]]+(list|status|get|show|history|template)([[:space:]]|$)'; then
  allow "read-only helm allowed"
fi

# ── Tier 2: safe automation (preview only — no live cluster mutation) ─────────
if printf '%s' "$NORM_COMMAND" | grep -qE '(^|[[:space:]])--dry-run(=|$|[[:space:]])'; then
  allow "dry-run preview allowed (no human gate)"
fi
if printf '%s' "$NORM_COMMAND" | grep -qE 'helm[[:space:]]+(upgrade|install|rollback)[[:space:]]+.*[[:space:]]--dry-run([[:space:]]|$)'; then
  allow "helm dry-run preview allowed"
fi

# ── Tier 2.6: safe rollout operations (restart/undo — no data loss) ──────────
# kubectl rollout restart and undo are safe: pods restart but data/PVs preserved,
# Sentinel/stateful controllers handle recovery. Destructive rollout ops (if any)
# and other mutations stay in Tier 3.
if printf '%s' "$NORM_COMMAND" | grep -qE 'kubectl[[:space:]]+(rollout[[:space:]]+(restart|undo))([[:space:]]|$)'; then
  allow "safe rollout operation (restart/undo) allowed"
fi

# ── Tier 2.5: read-only kubectl exec inner-command carve-out (additive) ───────
# Fires ONLY for `kubectl exec`. Classifies the inner command and auto-allows
# when every shell segment is independently read-only-safe; anything else falls
# through to the Tier 3 block_live() below, unchanged. Purely additive — it never
# widens what Tier 3/4 block for non-exec commands.
# Design + allow/deny table: reports/kube-hook/r-1_exec_classification.md
if printf '%s' "$COMMAND" | grep -qE 'kubectl([[:space:]]+[^[:space:]]+)*[[:space:]]+exec([[:space:]]|$)'; then
  _kube_exec_py="$(mktemp /tmp/.kube-exec.XXXXXX.py 2>/dev/null || echo "/tmp/.kube-exec-$$.py")"
  cat > "$_kube_exec_py" << 'PYEOF'
import re, sys, shlex

cmd = sys.argv[1] if len(sys.argv) > 1 else ''

def block():
    sys.exit(1)  # not classified safe → caller falls through to block_live

# 1. Require an explicit ' -- ' separator; left side must be a kubectl exec.
if ' -- ' not in cmd:
    block()
before, inner = cmd.split(' -- ', 1)
if not re.search(r'\bkubectl\b', before) or not re.search(r'\bexec\b', before):
    block()

# 2. Interactive flags never auto-allow.
if re.search(r'(^|\s)-(it|ti|i|t)(\s|$)', before) or re.search(r'--stdin|--tty', before):
    block()

inner = inner.strip()

# 3. Unwrap one sh/bash -c "<script>" layer.
m = re.match(r'^(?:/\S+/)?(?:sh|bash|ash|dash)\s+-c\s+(.+)$', inner)
if m:
    script = m.group(1).strip()
    if len(script) >= 2 and script[0] == script[-1] and script[0] in ('"', "'"):
        script = script[1:-1]
    inner = script.strip()

# A bare shell (no -c script) is interactive → block.
if re.match(r'^(?:/\S+/)?(?:sh|bash|ash|dash|zsh|ksh)(\s|$)', inner):
    block()

# 4. Reject expansion / redirection metacharacters.
if re.search(r'\$\(|`|>>|>|<\(', inner):
    block()

RO_TEXT = {'grep','egrep','fgrep','cat','head','tail','wc','ls','echo','true',':','sort','uniq','cut'}
HARD_DENY = {'sudo','eval','xargs','nohup','timeout','watch','sh','bash','ash','dash','zsh','ksh'}
FIND_BAD = {'-delete','-exec','-execdir','-ok','-okdir','-fprint','-fprintf','-fls','-fprint0'}
REDIS_RO = {'GET','EXISTS','TTL','PTTL','PING','KEYS','SCAN','TYPE','STRLEN','LLEN',
            'HGET','HGETALL','HKEYS','HLEN','SMEMBERS','LRANGE','ZRANGE','DBSIZE','INFO'}
REDIS_VAL_FLAGS = {'-h','-p','-n','-a','-u','-t','--user','--pass','--timeout'}
CH_VAL_FLAGS = {'-h', '--host', '--port', '-u', '--user', '--password', '-d', '--database',
                '--format', '--config-file', '--history_file', '--query'}
CH_MUTATING = {'INSERT', 'CREATE', 'DROP', 'ALTER', 'TRUNCATE', 'UPDATE', 'DELETE', 'RENAME',
               'ATTACH', 'DETACH', 'KILL', 'GRANT', 'REVOKE', 'OPTIMIZE', 'SYSTEM', 'EXCHANGE',
               'REPLACE', 'SET', 'WATCH'}
CH_SAFE_START = ('SELECT', 'SHOW', 'DESCRIBE', 'DESC', 'EXPLAIN')

def ch_query_is_ro(query):
    q = query.strip().upper()
    if not q.startswith(CH_SAFE_START):
        return False
    for kw in CH_MUTATING:
        if kw == 'SYSTEM':
            # SYSTEM <cmd> (e.g. "SYSTEM DROP CACHE") is a mutating command; a bare
            # "system." schema reference (e.g. "FROM system.tables") is not — only
            # block SYSTEM followed by whitespace + a command word, not a dot.
            if re.search(r'\bSYSTEM\s+[A-Z]', q):
                return False
            continue
        if re.search(r'\b' + kw + r'\b', q):
            return False
    return True

def seg_ok(seg):
    seg = seg.strip()
    if not seg:
        return True
    try:
        toks = shlex.split(seg)
    except ValueError:
        return False
    if not toks:
        return True
    base = toks[0].rsplit('/', 1)[-1]
    args = toks[1:]
    if base in HARD_DENY:
        return False
    if base in RO_TEXT or base == 'ps':
        return True
    if base == 'find':
        return not any(a in FIND_BAD for a in args)
    if base == 'env':
        if any('=' in a for a in args):
            return False
        return not any(not a.startswith('-') for a in args)
    if base == 'redis-cli':
        i, sub = 0, None
        while i < len(args):
            a = args[i]
            if a in REDIS_VAL_FLAGS:
                i += 2; continue
            if a.startswith('-'):
                i += 1; continue
            sub = a; break
        return sub is not None and sub.upper() in REDIS_RO
    if base == 'clickhouse-client':
        i, query = 0, None
        while i < len(args):
            a = args[i]
            if a in CH_VAL_FLAGS:
                if a == '--query':
                    query = args[i + 1] if i + 1 < len(args) else None
                i += 2; continue
            if a.startswith('--query='):
                query = a.split('=', 1)[1]
                i += 1; continue
            if a.startswith('-'):
                i += 1; continue
            i += 1
        return query is not None and ch_query_is_ro(query)
    return False

# 5. Decompose and require EVERY segment to pass.
for seg in re.split(r'\|\||\||&&|;|\n', inner):
    if not seg_ok(seg):
        block()

sys.exit(0)  # all segments read-only-safe → allow
PYEOF
  if python3 "$_kube_exec_py" "$COMMAND" 2>/dev/null; then
    rm -f "$_kube_exec_py"
    allow "read-only kubectl exec inner-command allowed"
  fi
  rm -f "$_kube_exec_py"
fi

# ── Tier 3: live mutating kubectl ────────────────────────────────────────────
if printf '%s' "$NORM_COMMAND" | grep -qE 'kubectl[[:space:]]+(scale|patch|rollout|apply|delete|replace|edit|set|annotate|label|cp|debug|proxy|port-forward|exec|drain|cordon|uncordon|taint|create)([[:space:]]|$)'; then
  block_live
fi

# ── Tier 4: live mutating helm ─────────────────────────────────────────────────
if printf '%s' "$NORM_COMMAND" | grep -qE 'helm[[:space:]]+(uninstall|delete|upgrade|install|rollback|reset)([[:space:]]|$)'; then
  block_live
fi

# Cluster wrapper scripts
if printf '%s' "$NORM_COMMAND" | grep -qE 'apply_round_config\.sh'; then
  block_live
fi

# Unknown kubectl/helm — block conservatively (agent should remediate or justify)
block_live
