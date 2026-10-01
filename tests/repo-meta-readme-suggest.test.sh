#!/usr/bin/env bash
# Coverage for suggest.py's README drafts — the validator for repos with no README.
#
# A README draft lands as a PR in the target repo, which may be public. So the
# checks that matter most are negative: no secret shapes, no personal paths, and
# for a public repo, no name of a private repo in the same owner. Each fixture
# breaks exactly one rule, so a failure names the rule that broke.
#
# `gh` is STUBBED: the private-name list comes from repos.json when it has
# private rows, and from `gh repo list` only when it does not.
#
# Bash 3.2-safe (repo convention).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUGGEST="$HERE/../.claude/skills/repo-meta/scripts/suggest.py"
TAX="$HERE/../.claude/skills/repo-meta/references/taxonomy.md"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  *"repo list acme"*"--visibility private"*) printf '[{"name":"secret-thing"}]\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log"
: > "$GH_LOG"

cat > "$TMP/repos.json" <<'JSON'
[{"nwo":"acme/widget","visibility":"public"},
 {"nwo":"acme/gadget","visibility":"private"},
 {"nwo":"acme/secret-thing","visibility":"private"}]
JSON

GOOD='# widget\n\nFolds laundry on a schedule and reports what it folded.\n\n## Usage\n\nRun it.\n'

# proposal <nwo> <visibility> <readme-json-string>
proposal() {
  printf '[{"nwo":"%s","visibility":"%s","has_readme":false,"current":{"description":null,"topics":[]},"proposed":{"description":"Folds laundry on a schedule","topics":["homelab","automation","python"],"readme":%s},"rationale":"r","engine":"agent","status":"needs_revision","violations":[]}]' "$1" "$2" "$3"
}

# check <label> <nwo> <visibility> <readme-json> <expected-status> [expected-violation-substring]
check() {
  proposal "$2" "$3" "$4" > "$TMP/one.json"
  python3 "$SUGGEST" --validate-only --proposals "$TMP/one.json" --repos "$TMP/repos.json" \
    --taxonomy "$TAX" --out "$TMP/v.json" >/dev/null 2>&1
  st="$(jq -r '.[0].status' "$TMP/v.json" 2>/dev/null)"
  vs="$(jq -r '.[0].violations | join(",")' "$TMP/v.json" 2>/dev/null)"
  [ "$st" = "$5" ] || { echo "  $1: expected status $5, got '$st' ($vs)"; fail=1; return; }
  if [ -n "${6:-}" ]; then
    case "$vs" in *"$6"*) : ;; *) echo "  $1: expected a '$6' violation, got '$vs'"; fail=1 ;; esac
  fi
}

check "clean draft"            acme/widget public "\"$GOOD\"" ok
check "empty"                  acme/widget public '"   "' needs_revision readme_empty
check "no H1"                  acme/widget public '"Folds laundry.\n"' needs_revision readme_no_h1
check "heading before summary" acme/widget public '"# widget\n\n## Usage\n\nRun it.\n"' needs_revision readme_no_summary
long="$(python3 -c 'print(repr("# widget\n\nFolds laundry.\n" + "line\n" * 130).replace(chr(39), chr(34)))')"
check "too long"               acme/widget public "$long" needs_revision readme_too_long
# Secret-shaped fixtures are assembled at run time, so secret scanners on this
# public repo don't flag the test file itself.
secret_check() { # <label> <prefix> <body>
  check "$1" acme/widget public "\"# widget\\n\\nFolds laundry. Key $2$3.\\n\"" needs_revision readme_secret
}
secret_check "openai-style key" "sk" "-abcdefghijklmnop1234"
secret_check "github token"     "ghp" "_abcdefghijklmnopqrstuvwxyz0123456789"
secret_check "slack token"      "xox" "b-1234567890-abcdef"
secret_check "aws key"          "AK" "IAABCDEFGHIJKLMNOP"
secret_check "private key"      "-----BEGIN RSA PRI" "VATE KEY-----"
# Built at run time: this repo's leak check refuses a literal macOS home prefix.
MACHOME="$(printf '/%s/' Users)someone"
check "mac home path"          acme/widget public "\"# widget\\n\\nFolds laundry from $MACHOME/laundry.\\n\"" needs_revision readme_personal_path
check "linux home path"        acme/widget public '"# widget\n\nFolds laundry from /home/someone/laundry.\n"' needs_revision readme_personal_path
check "tilde path"             acme/widget public '"# widget\n\nFolds laundry into ~/laundry.\n"' needs_revision readme_personal_path
# "desk-" contains "sk-" but is not a key; the boundary must hold.
check "sk- inside a word"      acme/widget public '"# widget\n\nRuns the help-desk-tracker.\n"' ok

# --- private names -----------------------------------------------------------
check "public names a private repo"  acme/widget public '"# widget\n\nFeeds data to Secret-Thing nightly.\n"' needs_revision readme_private_name
check "private names a private repo" acme/gadget private '"# gadget\n\nFeeds data to secret-thing nightly.\n"' ok
# Hyphen-aware boundary: a longer name that merely contains a private name is not a hit.
check "longer name, no hit"          acme/widget public '"# widget\n\nForked from secret-thing-public.\n"' ok
# Unknown visibility fails closed and is treated as public.
check "unknown visibility"           acme/widget "" '"# widget\n\nFeeds secret-thing.\n"' needs_revision readme_private_name
[ ! -s "$GH_LOG" ] || { echo "  repos.json had private rows, yet gh was called: $(cat "$GH_LOG")"; fail=1; }

# repos.json without private rows: the list comes from gh.
printf '[{"nwo":"acme/widget","visibility":"public"}]\n' > "$TMP/repos-public.json"
proposal acme/widget public '"# widget\n\nFeeds secret-thing.\n"' > "$TMP/one.json"
python3 "$SUGGEST" --validate-only --proposals "$TMP/one.json" --repos "$TMP/repos-public.json" \
  --taxonomy "$TAX" --out "$TMP/v.json" >/dev/null 2>&1
grep -q "repo list acme" "$GH_LOG" || { echo "  no private rows in repos.json, but gh was not asked"; fail=1; }
jq -e '.[0].violations | map(startswith("readme_private_name")) | any' "$TMP/v.json" >/dev/null 2>&1 \
  || { echo "  private name from gh not enforced: $(jq -c '.[0].violations' "$TMP/v.json" 2>/dev/null)"; fail=1; }

# The private list cannot be had: fail closed.
printf '[{"nwo":"other/widget","visibility":"public"}]\n' > "$TMP/repos-other.json"
proposal other/widget public "\"$GOOD\"" > "$TMP/one.json"
python3 "$SUGGEST" --validate-only --proposals "$TMP/one.json" --repos "$TMP/repos-other.json" \
  --taxonomy "$TAX" --out "$TMP/v.json" >/dev/null 2>&1
jq -e '.[0].status == "needs_revision" and (.[0].violations | index("readme_private_names_unchecked") != null)' \
  "$TMP/v.json" >/dev/null 2>&1 \
  || { echo "  an unknown private list must fail closed: $(jq -c '.[0].violations' "$TMP/v.json" 2>/dev/null)"; fail=1; }

# --- never rewrite an existing README ----------------------------------------
printf '[{"nwo":"acme/widget","visibility":"public","has_readme":true,"current":{"description":null,"topics":[]},"proposed":{"description":"Folds laundry on a schedule","topics":["homelab","automation","python"],"readme":"%s"},"rationale":"r","engine":"agent","status":"ok","violations":[]}]' "$GOOD" > "$TMP/one.json"
python3 "$SUGGEST" --validate-only --proposals "$TMP/one.json" --repos "$TMP/repos.json" \
  --taxonomy "$TAX" --out "$TMP/v.json" >/dev/null 2>&1
jq -e '.[0].violations | index("readme_exists") != null' "$TMP/v.json" >/dev/null 2>&1 \
  || { echo "  a README draft for a repo that has one must be rejected"; fail=1; }

# --- the agent engine queues a README only where one is missing ---------------
mkdir -p "$TMP/profiles"
cat > "$TMP/profiles/acme__widget.json" <<'JSON'
{"nwo":"acme/widget","source":"local","sha":"a","has_readme":false,"readme_head":null,
 "claude_md_head":"# CLAUDE.md\n\nFolds laundry.","manifests":{},"tree":["src/"],"languages":{},
 "recent_commits":["feat: go"],"current":{"description":null,"topics":[]},"signals":{}}
JSON
cat > "$TMP/profiles/acme__gadget.json" <<'JSON'
{"nwo":"acme/gadget","source":"local","sha":"b","has_readme":true,"readme_head":"# gadget\n\nIt gadgets.",
 "claude_md_head":null,"manifests":{},"tree":["src/"],"languages":{},
 "recent_commits":["feat: go"],"current":{"description":null,"topics":[]},"signals":{}}
JSON
unset REPO_META_LOCAL_LLM
python3 "$SUGGEST" --profiles "$TMP/profiles" --repos "$TMP/repos.json" --taxonomy "$TAX" \
  --engine agent --out "$TMP/prop.json" >/dev/null 2>&1
jq -e '.[] | select(.nwo == "acme/widget") | (.proposed | has("readme")) and .proposed.readme == null and .has_readme == false and .visibility == "public"' \
  "$TMP/prop.json" >/dev/null 2>&1 \
  || { echo "  repo without README did not get a readme placeholder: $(jq -c '.' "$TMP/prop.json" 2>/dev/null)"; fail=1; }
jq -e '.[] | select(.nwo == "acme/gadget") | .proposed | has("readme") | not' "$TMP/prop.json" >/dev/null 2>&1 \
  || { echo "  repo WITH a README must not get a readme slot"; fail=1; }

[ "$fail" -eq 0 ] && echo "repo-meta-readme-suggest: PASS" || echo "repo-meta-readme-suggest: FAIL"
exit "$fail"
