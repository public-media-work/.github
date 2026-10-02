#!/usr/bin/env bash
# Coverage for suggest.py — taxonomy parsing, validation, and --engine none.
#
# No model is involved here. --engine none is deterministic, which is what makes
# the VALIDATOR testable in isolation: every rule gets a hand-built proposal that
# violates exactly one thing, so a failure names the rule that broke.
#
# Bash 3.2-safe (repo convention).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUGGEST="$HERE/../.claude/skills/repo-meta/scripts/suggest.py"
TAX="$HERE/../.claude/skills/repo-meta/references/taxonomy.md"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- taxonomy parses --------------------------------------------------------
python3 "$SUGGEST" --dump-taxonomy --taxonomy "$TAX" > "$TMP/tax.json" 2>/dev/null
[ -s "$TMP/tax.json" ] || { echo "  --dump-taxonomy produced nothing"; fail=1; }
jq -e '.domain | index("homelab") != null' "$TMP/tax.json" >/dev/null 2>&1 \
  || { echo "  domain terms not parsed"; fail=1; }
jq -e '.function | index("mcp-server") != null' "$TMP/tax.json" >/dev/null 2>&1 \
  || { echo "  function terms not parsed"; fail=1; }
jq -e '.technology | index("fastapi") != null' "$TMP/tax.json" >/dev/null 2>&1 \
  || { echo "  technology terms not parsed"; fail=1; }
jq -e '.domain | index("python") == null' "$TMP/tax.json" >/dev/null 2>&1 \
  || { echo "  technology term leaked into domain"; fail=1; }

# --- validator: one violation each ------------------------------------------
check_violation() { # <label> <json> <expected-substring>
  printf '%s' "$2" > "$TMP/one.json"
  got="$(python3 "$SUGGEST" --validate-only --proposals "$TMP/one.json" \
         --taxonomy "$TAX" --out "$TMP/v.json" 2>/dev/null; \
         jq -r '.[0].violations | join(",")' "$TMP/v.json" 2>/dev/null)"
  case "$got" in
    *"$3"*) : ;;
    *) echo "  $1: expected a '$3' violation, got '$got'"; fail=1 ;;
  esac
}

ok='[{"nwo":"me/a","current":{"description":null,"topics":[]},"proposed":{"description":"Folds laundry on a schedule","topics":["homelab","automation","python"]},"rationale":"r","engine":"none","status":"ok","violations":[]}]'
printf '%s' "$ok" > "$TMP/ok.json"
python3 "$SUGGEST" --validate-only --proposals "$TMP/ok.json" --taxonomy "$TAX" --out "$TMP/vok.json" >/dev/null 2>&1
[ "$(jq -r '.[0].status' "$TMP/vok.json" 2>/dev/null)" = "ok" ] \
  || { echo "  a clean proposal was rejected: $(jq -c '.[0].violations' "$TMP/vok.json" 2>/dev/null)"; fail=1; }

# An agent-engine proposal the session agent has since filled in must be able to
# pass. Forcing every engine=agent row to needs_revision made the documented
# "fill it in, then --validate-only" loop impossible to finish.
filled='[{"nwo":"me/a","current":{"description":null,"topics":[]},"proposed":{"description":"Folds laundry on a schedule","topics":["homelab","automation","python"]},"rationale":"r","engine":"agent","status":"needs_revision","violations":[]}]'
printf '%s' "$filled" > "$TMP/filled.json"
python3 "$SUGGEST" --validate-only --proposals "$TMP/filled.json" --taxonomy "$TAX" --out "$TMP/vfilled.json" >/dev/null 2>&1
[ "$(jq -r '.[0].status' "$TMP/vfilled.json" 2>/dev/null)" = "ok" ] \
  || { echo "  a filled-in agent proposal stayed needs_revision"; fail=1; }

jq -e '.domain | index("wpm") != null' "$TMP/tax.json" >/dev/null 2>&1 \
  || { echo "  wpm domain term missing"; fail=1; }

long="$(python3 -c 'print("x"*400)')"
check_violation "too long" \
  "[{\"nwo\":\"me/a\",\"current\":{\"description\":null,\"topics\":[]},\"proposed\":{\"description\":\"$long\",\"topics\":[\"homelab\",\"automation\"]},\"rationale\":\"r\",\"engine\":\"none\",\"status\":\"ok\",\"violations\":[]}]" \
  "description_too_long"

check_violation "buzzword" \
  '[{"nwo":"me/a","current":{"description":null,"topics":[]},"proposed":{"description":"A powerful seamless solution","topics":["homelab","automation"]},"rationale":"r","engine":"none","status":"ok","violations":[]}]' \
  "buzzword"

check_violation "too few topics" \
  '[{"nwo":"me/a","current":{"description":null,"topics":[]},"proposed":{"description":"Folds laundry","topics":["homelab","automation"]},"rationale":"r","engine":"none","status":"ok","violations":[]}]' \
  "topic_count"

check_violation "no domain term" \
  '[{"nwo":"me/a","current":{"description":null,"topics":[]},"proposed":{"description":"Folds laundry","topics":["automation","python","fastapi"]},"rationale":"r","engine":"none","status":"ok","violations":[]}]' \
  "no_domain_term"

check_violation "no function term" \
  '[{"nwo":"me/a","current":{"description":null,"topics":[]},"proposed":{"description":"Folds laundry","topics":["homelab","python","fastapi"]},"rationale":"r","engine":"none","status":"ok","violations":[]}]' \
  "no_function_term"

check_violation "bad topic format" \
  '[{"nwo":"me/a","current":{"description":null,"topics":[]},"proposed":{"description":"Folds laundry","topics":["HomeLab","automation","python"]},"rationale":"r","engine":"none","status":"ok","violations":[]}]' \
  "topic_format"

check_violation "restates the name" \
  '[{"nwo":"me/widget","current":{"description":null,"topics":[]},"proposed":{"description":"widget","topics":["homelab","automation","python"]},"rationale":"r","engine":"none","status":"ok","violations":[]}]' \
  "restates_name"

# --- engine none: topics only, never a description --------------------------
mkdir -p "$TMP/profiles"
cat > "$TMP/profiles/me__thing.json" <<'JSON'
{"nwo":"me/thing","source":"local","sha":"abc","readme_head":"# thing\n\nRuns the homelab.",
 "manifests":{},"tree":["src/"],"languages":{"Python":900},"recent_commits":["feat: go"],
 "current":{"description":null,"topics":[]},
 "signals":{"dockerfile":false,"github_workflows":false,"skill":false,"claude_plugin":false,"adr":false}}
JSON
python3 "$SUGGEST" --profiles "$TMP/profiles" --taxonomy "$TAX" \
  --engine none --out "$TMP/prop.json" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  --engine none exited $rc"; fail=1; }
[ "$(jq -r '.[0].proposed.description' "$TMP/prop.json" 2>/dev/null)" = "null" ] \
  || { echo "  --engine none must never propose a description"; fail=1; }
[ "$(jq -r '.[0].engine' "$TMP/prop.json" 2>/dev/null)" = "none" ] \
  || { echo "  engine field not recorded"; fail=1; }

[ "$fail" -eq 0 ] && echo "repo-meta-suggest: PASS" || echo "repo-meta-suggest: FAIL"
exit "$fail"
