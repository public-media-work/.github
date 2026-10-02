#!/usr/bin/env bash
# Coverage for local_engine.py — the oMLX call and, more importantly, what
# happens when it refuses.
#
# local_llm.py is STUBBED. The real endpoint's availability depends on this
# machine's free RAM: on 2026-08-24 it rejected a prefill outright and killed a
# session. A test against it would be green or red by accident. The stub pins
# both shapes — a good JSON reply, and the prefill_memory_exceeded refusal — so
# the FALLBACK is what gets tested, which is the part that actually failed.
#
# Bash 3.2-safe (repo convention).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../.claude/skills/repo-meta/scripts"
TAX="$HERE/../.claude/skills/repo-meta/references/taxonomy.md"
fail=0
# The operator's own REPO_META_LOCAL_LLM must not decide which engine these runs use.
unset REPO_META_LOCAL_LLM

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/profiles"
i=1
while [ "$i" -le 3 ]; do
  cat > "$TMP/profiles/me__r$i.json" <<JSON
{"nwo":"me/r$i","source":"local","sha":"a$i","readme_head":"# r$i\n\nWatches the homelab.",
 "manifests":{},"tree":["src/"],"languages":{"Python":900},"recent_commits":["feat: go"],
 "current":{"description":null,"topics":[]},
 "signals":{"dockerfile":false,"github_workflows":false,"skill":false,"claude_plugin":false,"adr":false}}
JSON
  i=$((i + 1))
done

# --- stub 1: a well-formed reply -------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/local_llm.py" <<'STUB'
#!/usr/bin/env python3
import json, sys
print(json.dumps({"description": "Watches the homelab and reports drift",
                  "topics": ["homelab", "automation", "python"],
                  "rationale": "readme + language stats"}))
STUB
chmod +x "$TMP/bin/local_llm.py"

python3 "$S/suggest.py" --profiles "$TMP/profiles" --taxonomy "$TAX" \
  --engine local --out "$TMP/good.json" \
  --local-llm "$TMP/bin/local_llm.py" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  local engine exited $rc"; fail=1; }
[ "$(jq -r '.[0].proposed.description' "$TMP/good.json" 2>/dev/null)" \
   = "Watches the homelab and reports drift" ] \
  || { echo "  model description not carried through"; fail=1; }
[ "$(jq -r '[.[] | select(.status=="ok")] | length' "$TMP/good.json" 2>/dev/null)" = "3" ] \
  || { echo "  expected 3 clean proposals"; fail=1; }
[ "$(jq -r '.[0].engine' "$TMP/good.json" 2>/dev/null)" = "local" ] \
  || { echo "  engine should record as local"; fail=1; }

# --- stub 2: the memory guard refuses --------------------------------------
cat > "$TMP/bin/local_llm.py" <<'STUB'
#!/usr/bin/env python3
import sys
sys.stderr.write('{"error":{"message":"oMLX prefill memory guard rejected this '
                 'prompt: Prefill would require ~22.08 GB peak but dynamic '
                 'ceiling is 21.74 GB","code":"prefill_memory_exceeded"}}\n')
sys.exit(1)
STUB
chmod +x "$TMP/bin/local_llm.py"

python3 "$S/suggest.py" --profiles "$TMP/profiles" --taxonomy "$TAX" \
  --engine local --out "$TMP/degraded.json" \
  --local-llm "$TMP/bin/local_llm.py" > "$TMP/log.txt" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  a refusing endpoint must not be fatal (exit $rc)"; fail=1; }

n="$(jq 'length' "$TMP/degraded.json" 2>/dev/null)"
[ "$n" = "3" ] || { echo "  expected all 3 repos still present, got $n"; fail=1; }

[ "$(jq -r '[.[] | select(.engine=="agent")] | length' "$TMP/degraded.json" 2>/dev/null)" = "3" ] \
  || { echo "  remaining repos should switch to the agent engine"; fail=1; }

[ "$(jq -r '[.[] | select(.status=="needs_revision")] | length' "$TMP/degraded.json" 2>/dev/null)" = "3" ] \
  || { echo "  degraded proposals must be marked needs_revision"; fail=1; }

jq -e '[.[] | select(.proposed.description != null)] | length == 0' "$TMP/degraded.json" >/dev/null 2>&1 \
  || { echo "  a degraded run must not emit invented descriptions"; fail=1; }

grep -qi "prefill_memory_exceeded\|falling back\|agent" "$TMP/log.txt" \
  || { echo "  the fallback was silent; it must say so on stderr"; fail=1; }

# --- stub 3: unparseable output is per-repo, not fatal ---------------------
cat > "$TMP/bin/local_llm.py" <<'STUB'
#!/usr/bin/env python3
print("Sure! Here is your description:")
STUB
chmod +x "$TMP/bin/local_llm.py"
python3 "$S/suggest.py" --profiles "$TMP/profiles" --taxonomy "$TAX" \
  --engine local --out "$TMP/junk.json" \
  --local-llm "$TMP/bin/local_llm.py" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  unparseable model output must not be fatal (exit $rc)"; fail=1; }
[ "$(jq -r '[.[] | select(.status=="needs_revision")] | length' "$TMP/junk.json" 2>/dev/null)" = "3" ] \
  || { echo "  unparseable output should mark needs_revision"; fail=1; }

# --- engine default follows REPO_META_LOCAL_LLM -----------------------------
# No local_llm.py path is baked in: its location is machine-specific. Unset, the
# default engine is agent; set, it is local and that script is the one called.
cat > "$TMP/bin/local_llm.py" <<'STUB'
#!/usr/bin/env python3
import json
print(json.dumps({"description": "Watches the homelab and reports drift",
                  "topics": ["homelab", "automation", "python"],
                  "rationale": "readme"}))
STUB
chmod +x "$TMP/bin/local_llm.py"

python3 "$S/suggest.py" --profiles "$TMP/profiles" --taxonomy "$TAX" \
  --out "$TMP/default-unset.json" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  default run with REPO_META_LOCAL_LLM unset exited $rc"; fail=1; }
[ "$(jq -r '[.[] | select(.engine=="agent")] | length' "$TMP/default-unset.json" 2>/dev/null)" = "3" ] \
  || { echo "  with REPO_META_LOCAL_LLM unset the default engine should be agent"; fail=1; }

REPO_META_LOCAL_LLM="$TMP/bin/local_llm.py" python3 "$S/suggest.py" \
  --profiles "$TMP/profiles" --taxonomy "$TAX" --out "$TMP/default-set.json" >/dev/null 2>&1
[ "$(jq -r '[.[] | select(.engine=="local" and .status=="ok")] | length' "$TMP/default-set.json" 2>/dev/null)" = "3" ] \
  || { echo "  with REPO_META_LOCAL_LLM set the default engine should be local"; fail=1; }

# --- explicit --engine local with no script configured degrades, loudly ------
python3 "$S/suggest.py" --profiles "$TMP/profiles" --taxonomy "$TAX" \
  --engine local --out "$TMP/noscript.json" > "$TMP/noscript.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  --engine local with no script must not be fatal (exit $rc)"; fail=1; }
[ "$(jq -r '[.[] | select(.engine=="agent" and .status=="needs_revision")] | length' "$TMP/noscript.json" 2>/dev/null)" = "3" ] \
  || { echo "  --engine local with no script should fall back to agent"; fail=1; }
grep -q "REPO_META_LOCAL_LLM" "$TMP/noscript.log" \
  || { echo "  the missing-script fallback should name REPO_META_LOCAL_LLM"; fail=1; }

[ "$fail" -eq 0 ] && echo "repo-meta-local-engine: PASS" || echo "repo-meta-local-engine: FAIL"
exit "$fail"
