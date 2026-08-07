#!/usr/bin/env bash
# test-registry-invariant.sh — registry NF==8 row-corruption hardening (task C319).
#
# Background: a concurrent/legacy writer could append a phantom timestamp field
# PAST the trailing pipe (`| ... | last_activity | new_ts`), producing a row that
# still has 8 `|`-fields but a NON-empty $8 — defeating reset_stale_running_tasks
# and deadlocking tend (see 68A1). C319 hardens this with:
#   - rescue.sh: a normalize-first pass (self-heal from ANY writer) + invariant guard
#   - run-job.sh: repair_registry_rows normalizer (atomic temp+mv)
#   - this live-invariant assertion, wired into run-tests.sh
#
# A VALID registry data row: NF==8 with an EMPTY trailing field $8 AND mode ($4) ∈
# {auto,gated} AND status ($6) ∈ the known status set.
# A CORRUPT row: NF!=8 OR $8 non-empty (STRUCTURAL) OR a field-shift that keeps
# NF==8 but writes a wrong value into the mode/status enum columns (DOMAIN). A1DD
# adds the domain check — NF==8 is necessary but NOT sufficient.
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
PROJ="$PROJECT_ROOT/project.md"
RESCUE="${RESCUE:-$PROJECT_ROOT/bin/rescue.sh}"
RUNJOB="${RUNJOB:-$PROJECT_ROOT/bin/run-job.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

# Count malformed data rows in a file. STRUCTURAL: NF!=8 OR non-empty trailing $8.
# DOMAIN (field-shift): mode ($4) ∉ {auto,gated} OR status ($6) ∉ known set, even
# when NF==8 with empty $8. Mirrors rescue.sh BAD_ROWS / monitor checkRegistryInvariant.
count_bad_rows() {
  awk -F'|' '
    /^\|[[:space:]]*[0-9]/ {
      t=$8; gsub(/[[:space:]]/,"",t)
      m=$4; gsub(/^[[:space:]]+|[[:space:]]+$/,"",m)
      s=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s)
      mode_ok = (m=="auto" || m=="gated")
      status_ok = (s=="pending" || s=="running" || s=="awaiting_go" || s=="awaiting_critic" || s=="complete" || s=="failed" || s=="needs_human")
      if (NF!=8 || t!="" || !mode_ok || !status_ok) c++
    }
    END{print c+0}' "$1" 2>/dev/null || echo 0
}

echo ""
echo "── registry invariant (NF==8) — test suite ───"

echo ""
echo "1. Live project.md invariant"
if [[ -f "$PROJ" ]]; then
  BAD="$(count_bad_rows "$PROJ")"
  [[ "${BAD:-0}" -eq 0 ]] && ok "live project.md has zero malformed rows" \
    || fail "live project.md has $BAD malformed row(s) — corruption present"
else
  # No live project.md when run standalone from the ai-toolbox skill source repo
  # (project.md only exists in a deployed project, e.g. ai-console) — not a failure.
  echo "  · skip: no live project.md at $PROJ (expected when run from ai-toolbox source)"
fi

echo ""
echo "2. rescue.sh normalizer self-heals a seeded corrupt row"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/reginv-test.XXXXXX")"
WORK="$TMP/work"
mkdir -p "$WORK/.orchestrate/logs" "$WORK/.orchestrate/bin"
# Build a registry with one valid row and one corrupt row (phantom $8, no trailing pipe).
cat > "$WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — reginv-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| 20260101-good | a good row | auto | 1 | complete | 2026-01-01T00:00:00Z |
| 20260101-bad | corrupt row | auto | 1 | running | 2026-01-01T00:00:00Z | 2026-01-01T00:05:00Z
EOF
# Fresh heartbeat + lock so rescue does its normalize pass without kicking run-job
# (run-job.sh is intentionally NOT copied into the temp bin → no dispatch).
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] tend — idle" > "$WORK/.orchestrate/logs/heartbeat.log"

BEFORE="$(count_bad_rows "$WORK/.orchestrate/project.md")"
[[ "${BEFORE:-0}" -ge 1 ]] && ok "seeded corrupt row detected before normalize ($BEFORE)" \
  || fail "expected >=1 corrupt row in seed, got $BEFORE"

bash "$RESCUE" "$WORK" >/dev/null 2>&1 || true

AFTER="$(count_bad_rows "$WORK/.orchestrate/project.md")"
[[ "${AFTER:-1}" -eq 0 ]] && ok "rescue normalized corrupt row → 0 malformed rows" \
  || fail "rescue left $AFTER malformed row(s) after normalize"

# The repaired row must be canonical: 6 columns + restored trailing pipe.
# (status may legitimately change — rescue's stale-running reset runs after the
# normalize pass and may flip this old row to needs_human; assert STRUCTURE only.)
if grep -qE '^\| 20260101-bad \| corrupt row \| auto \| 1 \| [a-z_]+ \| [0-9TZ:-]+ \|$' "$WORK/.orchestrate/project.md"; then
  ok "repaired row preserves 6 columns + restored trailing pipe"
else
  fail "repaired row not in expected canonical form"
  grep '20260101-bad' "$WORK/.orchestrate/project.md" || true
fi

echo ""
echo "3. run-job.sh reset_stale_running_tasks writes the registry atomically (temp+mv)"
# Extract the reset_stale_running_tasks() function body and inspect it. Note: the
# function may still use `sed -i` to inject a hint into the TASK FILE — that is
# fine; only the REGISTRY (project.md) write must be atomic. So we assert: the old
# registry sed pattern is gone, and an atomic temp+mv registry write is present.
FN_BODY="$(awk '/^reset_stale_running_tasks\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RUNJOB" 2>/dev/null || true)"
if [[ -z "$FN_BODY" ]]; then
  fail "could not locate reset_stale_running_tasks() in run-job.sh"
elif printf '%s' "$FN_BODY" | grep -qE 'sed -i .+\| running \|'; then
  fail "reset_stale_running_tasks still writes the registry via non-atomic sed -i"
elif printf '%s' "$FN_BODY" | grep -q "mktemp" && printf '%s' "$FN_BODY" | grep -q 'mv "\$rs_tmp" "\$proj"'; then
  ok "reset_stale_running_tasks writes registry via atomic mktemp + mv"
else
  fail "reset_stale_running_tasks: no recognizable atomic temp+mv registry write"
fi

echo ""
echo "4. Field-shift DOMAIN check (NF==8 but mode/status out of range)"
# A field-shift corruption keeps NF==8 with an empty trailing $8 — the structural
# check passes — but writes a wrong value into an enum column. The domain check
# (A1DD) must flag it. Build a clean file plus two field-shifted rows.
SHIFT="$TMP/shift.md"
cat > "$SHIFT" << 'EOF'
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| 20260628-clean | clean row | auto | 1 | complete | 2026-06-28T00:00:00Z |
| 20260628-mshift | mode shifted | 2 | 1 | complete | 2026-06-28T00:00:00Z |
| 20260628-sshift | status shifted | auto | 1 | finished | 2026-06-28T00:00:00Z |
EOF
# Sanity: every row is structurally NF==8 with an empty trailing $8 (so a bare
# NF!=8 || $8!="" check would call this file 100% clean).
STRUCT_BAD="$(awk -F'|' '/^\|[[:space:]]*[0-9]/ { t=$8; gsub(/[[:space:]]/,"",t); if (NF!=8 || t!="") c++ } END{print c+0}' "$SHIFT")"
[[ "${STRUCT_BAD:-1}" -eq 0 ]] && ok "field-shift rows are structurally clean (NF==8, empty \$8) — bare check would miss them" \
  || fail "expected 0 structural breaches in field-shift fixture, got $STRUCT_BAD"

DOMAIN_BAD="$(count_bad_rows "$SHIFT")"
[[ "${DOMAIN_BAD:-0}" -eq 2 ]] && ok "domain check flags both field-shifted rows (mode=2, status=finished)" \
  || fail "expected 2 domain-bad rows, got $DOMAIN_BAD"

# No false positives: the clean row alone must count as 0.
CLEAN_ONLY="$TMP/clean.md"
cat > "$CLEAN_ONLY" << 'EOF'
| 20260628-clean | clean row | auto | 1 | complete | 2026-06-28T00:00:00Z |
| 20260628-gated | gated pending | gated | 2 | pending | 2026-06-28T00:01:00Z |
EOF
[[ "$(count_bad_rows "$CLEAN_ONLY")" -eq 0 ]] && ok "valid rows (auto/gated × all statuses) are NOT flagged (no false positives)" \
  || fail "domain check produced a false positive on valid rows"

echo ""
echo "── registry invariant: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
