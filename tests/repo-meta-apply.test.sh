#!/usr/bin/env bash
# Coverage for apply.py — the only code in repo-meta that writes to GitHub.
#
# `gh` is STUBBED and records its argv. That is the point: the assertions are
# about WHICH commands would run, and the highest-value ones are negative —
# that dry-run issues none, and that a proposals file cannot be used in place
# of an approvals file.
#
# Bash 3.2-safe (repo convention).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY="$HERE/../.claude/skills/repo-meta/scripts/apply.py"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in *deny*) echo "HTTP 403: Resource not accessible" >&2; exit 1 ;; esac
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log"
: > "$GH_LOG"

cat > "$TMP/approvals.json" <<'JSON'
[{"nwo":"me/a","description":"Folds laundry on a schedule","add_topics":["homelab","automation"],"remove_topics":["old-thing"]},
 {"nwo":"me/b","description":null,"add_topics":["personal"],"remove_topics":[]},
 {"nwo":"org/deny","description":"Nope","add_topics":["automation"],"remove_topics":[]}]
JSON

# --- dry-run writes nothing -------------------------------------------------
python3 "$APPLY" --approvals "$TMP/approvals.json" --state-dir "$TMP/state" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  dry-run exited $rc"; fail=1; }
[ ! -s "$GH_LOG" ] || { echo "  DRY-RUN ISSUED gh COMMANDS: $(cat "$GH_LOG")"; fail=1; }

# --- proposals.json must be refused -----------------------------------------
cat > "$TMP/proposals.json" <<'JSON'
[{"nwo":"me/a","current":{"description":null,"topics":[]},"proposed":{"description":"x","topics":["homelab","automation","python"]},"rationale":"r","engine":"none","status":"ok","violations":[]}]
JSON
python3 "$APPLY" --approvals "$TMP/proposals.json" --state-dir "$TMP/state" --commit >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] || { echo "  a proposals file was accepted as approvals"; fail=1; }
[ ! -s "$GH_LOG" ] || { echo "  refused input still issued gh commands"; fail=1; }

# --- --commit issues the right calls ----------------------------------------
: > "$GH_LOG"
python3 "$APPLY" --approvals "$TMP/approvals.json" --state-dir "$TMP/state" --commit >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  --commit exited $rc; a 403 on one repo must not be fatal"; fail=1; }

grep -q -- "--description Folds laundry on a schedule" "$GH_LOG" \
  || { echo "  description edit not issued"; fail=1; }
grep -q -- "--add-topic homelab,automation" "$GH_LOG" \
  || { echo "  topic additions not batched into one call"; fail=1; }
grep -q -- "--remove-topic old-thing" "$GH_LOG" \
  || { echo "  topic removal not issued"; fail=1; }
grep -q "me/b" "$GH_LOG" \
  || { echo "  me/b was skipped entirely"; fail=1; }
grep -q -- "me/b --description" "$GH_LOG" \
  && { echo "  a null description must not be written"; fail=1; }

# --- the run log records the failure ----------------------------------------
LOG="$(ls "$TMP/state/runs/"*.jsonl 2>/dev/null | head -1)"
[ -n "$LOG" ] || { echo "  no run log written"; fail=1; }
grep -q '"nwo": *"org/deny"' "$LOG" 2>/dev/null \
  || { echo "  denied repo missing from run log"; fail=1; }
python3 - "$LOG" <<'PY' || fail=1
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
deny = [r for r in rows if r["nwo"] == "org/deny"]
if not deny or deny[0].get("ok") is not False:
    print("  denied repo not recorded as ok:false"); raise SystemExit(1)
if not deny[0].get("error"):
    print("  denied repo has no error text"); raise SystemExit(1)
PY

# --- idempotence: a description equal to current is skipped -----------------
: > "$GH_LOG"
cat > "$TMP/same.json" <<'JSON'
[{"nwo":"me/a","description":"Folds laundry on a schedule","add_topics":[],"remove_topics":[],"current_description":"Folds laundry on a schedule"}]
JSON
python3 "$APPLY" --approvals "$TMP/same.json" --state-dir "$TMP/state" --commit >/dev/null 2>&1
grep -q -- "--description" "$GH_LOG" \
  && { echo "  an unchanged description was re-written"; fail=1; }

[ "$fail" -eq 0 ] && echo "repo-meta-apply: PASS" || echo "repo-meta-apply: FAIL"
exit "$fail"
