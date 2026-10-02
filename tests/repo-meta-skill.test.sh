#!/usr/bin/env bash
# Coverage for repo-meta's SKILL.md — frontmatter validity and reference drift.
#
# Prose cannot be unit-tested, but two failure modes here are mechanical: a
# malformed frontmatter block makes the skill un-loadable, and a script path
# that no longer exists makes the instructions un-followable. Both go stale
# silently. This checks those, not the writing.
#
# Bash 3.2-safe (repo convention).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE/../.claude/skills/repo-meta/SKILL.md"
DIR="$HERE/../.claude/skills/repo-meta"
fail=0

[ -f "$SKILL" ] || { echo "  no SKILL.md"; exit 1; }

head -1 "$SKILL" | grep -q '^---$' || { echo "  frontmatter must open on line 1"; fail=1; }
grep -q '^name: repo-meta$' "$SKILL" || { echo "  missing or wrong 'name:'"; fail=1; }
grep -q '^description: ' "$SKILL" || { echo "  missing 'description:'"; fail=1; }

# Description carries trigger phrases or the skill never fires.
grep '^description: ' "$SKILL" | grep -qi "trigger" \
  || { echo "  description should name its trigger phrases"; fail=1; }

# Match on BASENAME, not on a literal "scripts/" prefix. SKILL.md defines
# S="${CLAUDE_SKILL_DIR}/scripts" once and then writes
# "$S/discover.py" — which is the right way to write it, and which contains the
# string "scripts/" nowhere. Both loops below used to assume the literal prefix, so
# they failed in opposite directions at once: the forward loop matched nothing and
# passed vacuously, while the reverse loop reported every script as unmentioned.
# A test that is wrong in both directions still shows one red line, which is how it
# reads as a single small problem.
for f in "$DIR"/scripts/*.py; do
  b="$(basename "$f")"
  # Any path-ish reference counts: "$S/discover.py", scripts/discover.py, ./discover.py.
  grep -qE "[/\"']$b\b" "$SKILL" || { echo "  $b exists but SKILL.md never mentions it"; fail=1; }
done

# Every *.py basename the prose references must exist under scripts/.
for s in $(grep -oE '[A-Za-z_][A-Za-z0-9_]*\.py' "$SKILL" | sort -u); do
  [ -f "$DIR/scripts/$s" ] || { echo "  SKILL.md references missing scripts/$s"; fail=1; }
done

# The gate is the safety property; it must be stated, not implied.
grep -qi "approvals.json" "$SKILL" || { echo "  SKILL.md must name approvals.json"; fail=1; }
grep -qi -- "--commit" "$SKILL" || { echo "  SKILL.md must explain --commit"; fail=1; }
grep -qi "dry.run" "$SKILL" || { echo "  SKILL.md must state dry-run is the default"; fail=1; }

# The warning that the gate is procedural must survive edits: without it the
# prose reads as a technical control, which it is not.
grep -qi "procedural, not technical" "$SKILL" \
  || { echo "  SKILL.md must say the approval gate is procedural, not technical"; fail=1; }
grep -q -- "--org public-media-work" "$SKILL" \
  || { echo "  SKILL.md must document --org public-media-work as the invocation here"; fail=1; }
grep -q "REPO_META_LOCAL_LLM" "$SKILL" \
  || { echo "  SKILL.md must document REPO_META_LOCAL_LLM"; fail=1; }
grep -qi "provenance" "$SKILL" \
  || { echo "  SKILL.md must carry its provenance note"; fail=1; }

[ "$fail" -eq 0 ] && echo "repo-meta-skill: PASS" || echo "repo-meta-skill: FAIL"
exit "$fail"
