#!/usr/bin/env bash
# Coverage for profile.py — evidence extraction from a real checkout.
#
# The LOCAL path is tested against a real git repo built in a temp dir: profile.py
# reads files and runs git log, so a synthetic tree exercises the actual code path
# with no network. The CLONE path is tested by pointing a repo's origin at another
# local dir — git clone works file-to-file, so --depth=1 is genuinely exercised
# without reaching GitHub.
#
# Bash 3.2-safe (repo convention).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="$HERE/../.claude/skills/repo-meta/scripts/profile.py"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# --- a real little repo -----------------------------------------------------
R="$TMP/widget"
mkdir -p "$R/src" "$R/docs" "$R/.github/workflows"
printf '# widget\n\nA widget that folds laundry.\n' > "$R/README.md"
printf '{"name":"widget","description":"folds laundry","dependencies":{"left-pad":"1.0"}}\n' > "$R/package.json"
printf 'on: push\n' > "$R/.github/workflows/ci.yml"
printf 'print(1)\n' > "$R/src/main.py"
git -C "$R" init -q; git -C "$R" add -A
git -C "$R" commit -qm "feat: fold the laundry"
git -C "$R" commit -q --allow-empty -m "fix: stop eating socks"

cat > "$TMP/repos.json" <<JSON
[{"nwo":"me/widget","archived":false,"fork":false,"local_path":"$R",
  "description":null,"topics":[],"default_branch":"main",
  "languages":{"Python":100}}]
JSON

OUT="$TMP/profiles"
python3 "$PROFILE" --repos "$TMP/repos.json" --out "$OUT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  profile.py exited $rc"; fail=1; }

P="$OUT/me__widget.json"
[ -f "$P" ] || { echo "  expected $P"; fail=1; }

src="$(jq -r '.source' "$P" 2>/dev/null)"
[ "$src" = "local" ] || { echo "  expected source=local, got '$src'"; fail=1; }

jq -e '.readme_head | contains("folds laundry")' "$P" >/dev/null 2>&1 \
  || { echo "  readme_head missing README body"; fail=1; }

jq -e '.manifests["package.json"].description == "folds laundry"' "$P" >/dev/null 2>&1 \
  || { echo "  package.json description not extracted"; fail=1; }

jq -e '.signals.github_workflows == true' "$P" >/dev/null 2>&1 \
  || { echo "  workflows signal not detected"; fail=1; }

jq -e '.signals.dockerfile == false' "$P" >/dev/null 2>&1 \
  || { echo "  dockerfile signal should be false"; fail=1; }

n="$(jq -r '.recent_commits | length' "$P" 2>/dev/null)"
[ "$n" = "2" ] || { echo "  expected 2 commit subjects, got $n"; fail=1; }

jq -e '.tree | index("src/") != null' "$P" >/dev/null 2>&1 \
  || { echo "  tree missing src/"; fail=1; }

# --- tree is the committed tree, not the working directory ------------------
# A local checkout carries caches, worktrees and ignored settings a clone never
# has. Walking the directory let those crowd real entries out of the 60-entry
# cap, and made one repo's evidence depend on which machine profiled it.
mkdir -p "$R/.pytest_cache/v" && : > "$R/.pytest_cache/v/x" && : > "$R/.DS_Store"
python3 "$PROFILE" --repos "$TMP/repos.json" --out "$TMP/p-junk" >/dev/null 2>&1
jq -e '[.tree[] | select(startswith(".pytest_cache") or . == ".DS_Store")] | length == 0' \
  "$TMP/p-junk/me__widget.json" >/dev/null 2>&1 \
  || { echo "  untracked files leaked into tree: $(jq -c '.tree' "$TMP/p-junk/me__widget.json" 2>/dev/null)"; fail=1; }
rm -rf "$R/.pytest_cache" "$R/.DS_Store"

# --- caching: an unchanged repo must not be re-profiled ---------------------
before="$(jq -r '.sha' "$P")"
touch "$TMP/marker"; sleep 1
python3 "$PROFILE" --repos "$TMP/repos.json" --out "$OUT" >/dev/null 2>&1
[ "$P" -nt "$TMP/marker" ] && { echo "  cached profile was rewritten despite unchanged sha"; fail=1; }
[ "$(jq -r '.sha' "$P")" = "$before" ] || { echo "  sha changed on a no-op re-run"; fail=1; }

# --- clone path: origin points at a local dir, no network -------------------
cat > "$TMP/remote.json" <<JSON
[{"nwo":"me/remote-widget","archived":false,"fork":false,"local_path":null,
  "description":null,"topics":[],"default_branch":"main","languages":{}}]
JSON
python3 "$PROFILE" --repos "$TMP/remote.json" --out "$TMP/p2" \
  --clone-url-template "$R" >/dev/null 2>&1
P2="$TMP/p2/me__remote-widget.json"
[ -f "$P2" ] || { echo "  clone path produced no profile"; fail=1; }
[ "$(jq -r '.source' "$P2" 2>/dev/null)" = "clone" ] \
  || { echo "  expected source=clone"; fail=1; }
jq -e '.readme_head | contains("folds laundry")' "$P2" >/dev/null 2>&1 \
  || { echo "  cloned profile missing README"; fail=1; }

# --- failure is recorded, not fatal -----------------------------------------
cat > "$TMP/bad.json" <<'JSON'
[{"nwo":"me/nope","archived":false,"fork":false,"local_path":null,
  "description":null,"topics":[],"default_branch":"main","languages":{}}]
JSON
python3 "$PROFILE" --repos "$TMP/bad.json" --out "$TMP/p3" \
  --clone-url-template "/nonexistent/path" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  a clone failure must not be fatal (exit $rc)"; fail=1; }
jq -e '.["me/nope"]' "$TMP/p3/_errors.json" >/dev/null 2>&1 \
  || { echo "  clone failure not recorded in _errors.json"; fail=1; }

[ "$fail" -eq 0 ] && echo "repo-meta-profile: PASS" || echo "repo-meta-profile: FAIL"
exit "$fail"
