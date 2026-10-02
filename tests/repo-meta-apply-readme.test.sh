#!/usr/bin/env bash
# Coverage for apply.py's README step — a PR in the target repo, never a push.
#
# `gh` is STUBBED and records its argv. The stub answers the REST calls the
# README step makes, and env flags flip it into the cases that must skip: the
# branch already exists, an open PR already exists, or a README appeared on the
# default branch since the draft was made.
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
notfound() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case "$*" in
  "api repos/acme/widget")
    printf '{"default_branch":"trunk","visibility":"%s"}\n' "${STUB_VISIBILITY:-private}" ;;
  "repo list acme --visibility private --limit 1000"*) printf '[{"name":"secret-thing"},{"name":"old-archive"}]\n' ;;
  "api repos/acme/widget/readme?ref=trunk")
    [ -n "${STUB_README:-}" ] && { echo '{"name":"README.md"}'; exit 0; }; notfound ;;
  "api repos/acme/widget/git/ref/heads/docs/add-readme")
    [ -n "${STUB_BRANCH:-}" ] && { echo '{"ref":"refs/heads/docs/add-readme"}'; exit 0; }; notfound ;;
  "pr list -R acme/widget --head docs/add-readme --state open"*)
    [ -n "${STUB_PR:-}" ] && echo "https://github.com/acme/widget/pull/7"; exit 0 ;;
  "api repos/acme/widget/git/ref/heads/trunk"*) echo "abc123" ;;
  "api -X POST repos/acme/widget/git/refs"*) echo '{}' ;;
  "api -X PUT repos/acme/widget/contents/README.md"*) echo '{}' ;;
  "pr create -R acme/widget"*) echo "https://github.com/acme/widget/pull/8" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log"

README='# widget\n\nFolds laundry on a schedule.\n\n## Usage\n\nRun it.\n'
row() { # <readme-approved: true|false> [readme text]
  printf '[{"nwo":"acme/widget","add_topics":[],"remove_topics":[],"readme":%s,"readme_markdown":"%s"}]\n' \
    "$1" "${2:-$README}" > "$TMP/approvals.json"
}
run() { # <state-subdir> [--commit]
  : > "$GH_LOG"
  python3 "$APPLY" --approvals "$TMP/approvals.json" --state-dir "$TMP/$1" ${2:-} > "$TMP/out.txt" 2>&1
}
last_log() { ls "$TMP/$1/runs/"*.jsonl 2>/dev/null | tail -1; }
readme_row() { python3 - "$(last_log "$1")" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r = [x for x in rows if x.get("kind") == "readme"]
print(json.dumps(r[0] if r else None))
PY
}

# --- dry run: prints the plan, makes zero gh calls ---------------------------
row true
run s-dry
[ ! -s "$GH_LOG" ] || { echo "  DRY-RUN ISSUED gh COMMANDS: $(cat "$GH_LOG")"; fail=1; }
grep -q "docs/add-readme" "$TMP/out.txt" || { echo "  dry run did not describe the README branch"; fail=1; }
grep -qi "pull request\|pr create" "$TMP/out.txt" || { echo "  dry run did not describe the PR"; fail=1; }

# --- approved: ref-get, ref-create, PUT, pr create — in that order -----------
row true
run s-ok --commit
order="$(python3 - "$GH_LOG" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
want = ["api repos/acme/widget/git/ref/heads/trunk", "api -X POST repos/acme/widget/git/refs",
        "api -X PUT repos/acme/widget/contents/README.md", "pr create -R acme/widget"]
idx = []
for w in want:
    hit = [i for i, l in enumerate(lines) if l.startswith(w)]
    idx.append(hit[0] if hit else -1)
print("ok" if -1 not in idx and idx == sorted(idx) else "bad %s" % idx)
PY
)"
[ "$order" = "ok" ] || { echo "  README calls out of order or missing ($order): $(cat "$GH_LOG")"; fail=1; }
grep -q -- "-f ref=refs/heads/docs/add-readme -f sha=abc123" "$GH_LOG" \
  || { echo "  branch not created from the default branch head"; fail=1; }
grep -q -- "-f branch=docs/add-readme" "$GH_LOG" || { echo "  README not written to the docs branch"; fail=1; }
grep -q -- "--head docs/add-readme --base trunk" "$GH_LOG" || { echo "  PR head/base wrong"; fail=1; }
grep -q "body=@\|content=@" "$GH_LOG" && { echo "  -f with @file sends the literal path"; fail=1; }
# Never write to the default branch.
grep -E -- "contents/README.md" "$GH_LOG" | grep -q -- "-f branch=trunk" \
  && { echo "  README written to the DEFAULT branch"; fail=1; }
b64="$(grep -o -- '-f content=[^ ]*' "$GH_LOG" | head -1 | sed 's/^-f content=//')"
[ "$(printf '%s' "$b64" | python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode().splitlines()[0])' 2>/dev/null)" = "# widget" ] \
  || { echo "  PUT content is not the base64 of the approved README"; fail=1; }
r="$(readme_row s-ok)"
printf '%s' "$r" | jq -e '.ok == true and .pr_url == "https://github.com/acme/widget/pull/8"' >/dev/null 2>&1 \
  || { echo "  PR URL not recorded in the run log: $r"; fail=1; }

# --- unapproved README: nothing written ---------------------------------------
row false
run s-no --commit
grep -q "contents/README.md\|git/refs\|pr create" "$GH_LOG" \
  && { echo "  an unapproved README was written: $(cat "$GH_LOG")"; fail=1; }

# --- skips: branch exists, open PR exists, README appeared --------------------
skip_case() { # <label> <env assignment>
  row true
  : > "$GH_LOG"
  env "$2" python3 "$APPLY" --approvals "$TMP/approvals.json" --state-dir "$TMP/s-$1" --commit \
    > "$TMP/out.txt" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { echo "  $1: a skip must not be fatal (exit $rc)"; fail=1; }
  grep -q "git/refs\|contents/README.md\|pr create" "$GH_LOG" \
    && { echo "  $1: wrote despite the skip condition: $(cat "$GH_LOG")"; fail=1; }
  r="$(readme_row "s-$1")"
  printf '%s' "$r" | jq -e '.skipped != null' >/dev/null 2>&1 \
    || { echo "  $1: skip not recorded in the run log: $r"; fail=1; }
}
skip_case branch STUB_BRANCH=1
skip_case openpr STUB_PR=1
skip_case appeared STUB_README=1

# --- public repo: a private name in the approved text still stops the write ---
row true '# widget\n\nFeeds secret-thing nightly.\n'
: > "$GH_LOG"
STUB_VISIBILITY=public python3 "$APPLY" --approvals "$TMP/approvals.json" --state-dir "$TMP/s-leak" --commit \
  > "$TMP/out.txt" 2>&1
grep -q "git/refs\|contents/README.md\|pr create" "$GH_LOG" \
  && { echo "  a public README naming a private repo was written"; fail=1; }

# --- public repo: an archived private name from the live list stops it too ---
row true '# widget\n\nReplaces old-archive.\n'
: > "$GH_LOG"
STUB_VISIBILITY=public python3 "$APPLY" --approvals "$TMP/approvals.json" --state-dir "$TMP/s-arch" --commit \
  > "$TMP/out.txt" 2>&1
grep -q "repo list acme --visibility private --limit 1000" "$GH_LOG" \
  || { echo "  live private list not fetched with --limit 1000"; fail=1; }
grep -q "git/refs\|contents/README.md\|pr create" "$GH_LOG" \
  && { echo "  a public README naming an archived private repo was written"; fail=1; }

# --- an invalid approved README is refused before any gh call -----------------
row true "no heading, key $(printf '%s-%s' sk abcdefghijklmnop1234)\\n"
run s-bad --commit
[ ! -s "$GH_LOG" ] || { echo "  an invalid README reached gh: $(cat "$GH_LOG")"; fail=1; }

[ "$fail" -eq 0 ] && echo "repo-meta-apply-readme: PASS" || echo "repo-meta-apply-readme: FAIL"
exit "$fail"
