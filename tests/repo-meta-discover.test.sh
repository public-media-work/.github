#!/usr/bin/env bash
# Coverage for discover.py — repo-set resolution and the local-checkout join.
#
# `gh` is STUBBED. The real CLI returns live account data, so a test against it
# would assert on whatever repos exist today and rot immediately. The stub pins
# the two response shapes discover.py parses (/user/repos, /orgs/X/repos) so the
# FILTERING and the JOIN are what get tested.
#
# Bash 3.2-safe (repo convention).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISCOVER="$HERE/../.claude/skills/repo-meta/scripts/discover.py"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stub gh ----------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Only `gh api --paginate <path> --jq <expr>` is used. Echo canned JSON per path.
for a in "$@"; do case "$a" in
  */user/repos*) cat "$GH_STUB_USER"; exit 0 ;;
  */orgs/acme/repos*) cat "$GH_STUB_ORG"; exit 0 ;;
  */user/orgs*) echo '[{"login":"acme"}]'; exit 0 ;;
esac; done
echo '[]'
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

cat > "$TMP/user.json" <<'JSON'
[{"full_name":"me/live","archived":false,"fork":false,"description":"a thing","topics":["automation"],"default_branch":"main","language":"Python","visibility":"private","pushed_at":"2026-09-01T12:00:00Z"},
 {"full_name":"me/dead","archived":true,"fork":false,"description":null,"topics":[],"default_branch":"main","language":"Python"},
 {"full_name":"me/borrowed","archived":false,"fork":true,"description":null,"topics":[],"default_branch":"main","language":"Python"}]
JSON
cat > "$TMP/org.json" <<'JSON'
[{"full_name":"acme/widget","archived":false,"fork":false,"description":null,"topics":[],"default_branch":"main","language":"Python"}]
JSON
export GH_STUB_USER="$TMP/user.json" GH_STUB_ORG="$TMP/org.json"

# --- a fake workspace with one matching checkout ----------------------------
mkdir -p "$TMP/ws/live" && git -C "$TMP/ws/live" init -q 2>/dev/null
git -C "$TMP/ws/live" remote add origin https://github.com/me/live.git 2>/dev/null
mkdir -p "$TMP/ws/Backups/live" && git -C "$TMP/ws/Backups/live" init -q 2>/dev/null
git -C "$TMP/ws/Backups/live" remote add origin https://github.com/me/live.git 2>/dev/null

OUT="$TMP/repos.json"
python3 "$DISCOVER" --workspace "$TMP/ws" --out "$OUT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  discover.py exited $rc"; fail=1; }

# --- assertions -------------------------------------------------------------
n="$(jq 'length' "$OUT" 2>/dev/null)"
[ "$n" = "2" ] || { echo "  expected 2 active non-fork repos, got $n"; fail=1; }

jq -e '.[] | select(.nwo=="me/dead")' "$OUT" >/dev/null 2>&1 && { echo "  archived repo was not filtered"; fail=1; }
jq -e '.[] | select(.nwo=="me/borrowed")' "$OUT" >/dev/null 2>&1 && { echo "  fork was not filtered"; fail=1; }

lp="$(jq -r '.[] | select(.nwo=="me/live") | .local_path' "$OUT" 2>/dev/null)"
case "$lp" in
  */ws/live) : ;;
  *Backups*) echo "  local_path resolved into Backups/, which must be excluded"; fail=1 ;;
  *) echo "  expected local_path for me/live, got '$lp'"; fail=1 ;;
esac

# visibility and pushed_at carry through: refresh-org-profile's digest reads
# them for its pushed-since-refresh and visibility-changed flags.
jq -e '.[] | select(.nwo=="me/live") | .visibility == "private" and .pushed_at == "2026-09-01T12:00:00Z"' \
  "$OUT" >/dev/null 2>&1 || { echo "  visibility/pushed_at not carried into repos.json"; fail=1; }
jq -e '.[] | select(.nwo=="acme/widget") | has("visibility") and has("pushed_at")' \
  "$OUT" >/dev/null 2>&1 || { echo "  rows must always carry visibility and pushed_at keys"; fail=1; }

nl="$(jq -r '.[] | select(.nwo=="acme/widget") | .local_path' "$OUT" 2>/dev/null)"
[ "$nl" = "null" ] || { echo "  acme/widget has no checkout; expected null, got '$nl'"; fail=1; }

# --- --include-archived widens ----------------------------------------------
python3 "$DISCOVER" --workspace "$TMP/ws" --out "$TMP/all.json" --include-archived >/dev/null 2>&1
na="$(jq 'length' "$TMP/all.json" 2>/dev/null)"
[ "$na" = "3" ] || { echo "  --include-archived: expected 3, got $na"; fail=1; }

# --- --org limits to that org: personal repos are not swept in --------------
# `--org public-media-work` is the standard invocation in this repo. If it still
# listed /user/repos, an org-scoped run would propose metadata for the operator's
# personal repos too.
python3 "$DISCOVER" --workspace "$TMP/ws" --out "$TMP/org-only.json" --org acme >/dev/null 2>&1
no="$(jq -r '[.[].nwo] | join(",")' "$TMP/org-only.json" 2>/dev/null)"
[ "$no" = "acme/widget" ] || { echo "  --org acme: expected only acme/widget, got '$no'"; fail=1; }

# --- a rate-limited primary listing must FAIL LOUDLY, not emit a short file --
# The dangerous shape: gh returns non-zero, discover shrugs, and repos.json holds
# 4 repos instead of 72 while exiting 0. A later stage then "successfully"
# proposes metadata for a fraction of the account.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  */user/repos*) echo "API rate limit exceeded for user ID 1." >&2; exit 1 ;;
  */user/orgs*) echo '[]'; exit 0 ;;
esac; done
echo '[]'
STUB
chmod +x "$TMP/bin/gh"

out="$(REPO_META_GH_ATTEMPTS=1 python3 "$DISCOVER" --workspace "$TMP/ws" --out "$TMP/limited.json" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || { echo "  a rate-limited primary listing exited 0"; fail=1; }
[ ! -f "$TMP/limited.json" ] || { echo "  a rate-limited run still wrote repos.json"; fail=1; }
case "$out" in
  *"rate limited"*|*"rate limit"*) : ;;
  *) echo "  rate limiting was not reported; got: $(printf '%s' "$out" | head -c 120)"; fail=1 ;;
esac

[ "$fail" -eq 0 ] && echo "repo-meta-discover: PASS" || echo "repo-meta-discover: FAIL"
exit "$fail"
