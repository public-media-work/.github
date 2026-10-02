#!/usr/bin/env bash
# Coverage for org_profile.py — table render, leak checks, digest, stamp.
#
# No network: every gh call is replaced by --input / --private-json /
# --public-json fixtures. Fixture names are SYNTHETIC. This repo is public, so
# a real private repo name must never appear here, even as test data.
#
# The hyphen-boundary case is the one that matters most: private `secret-widget`
# must not match inside public `secret-widget-docs`.
#
# Bash 3.2-safe: no associative arrays, no mapfile.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP="$HERE/../.claude/skills/refresh-org-profile/scripts/org_profile.py"
pass=0
fail=0
ok(){ pass=$((pass+1)); }
bad(){ echo "  FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

cat > "$TMP/public.json" <<'JSON'
[{"name":"acme-tool","description":"Does a | thing","url":"https://github.com/acme-org/acme-tool","primaryLanguage":{"name":"Python"},"pushedAt":"2026-09-01T10:00:00Z","homepageUrl":""},
 {"name":"secret-widget-docs","description":"Public docs","url":"https://github.com/acme-org/secret-widget-docs","primaryLanguage":null,"pushedAt":"2026-09-20T10:00:00Z","homepageUrl":"https://example.org"},
 {"name":"beta-tool","description":null,"url":"https://github.com/acme-org/beta-tool","primaryLanguage":{"name":"Go"},"pushedAt":"2026-09-01T10:00:00Z","homepageUrl":null},
 {"name":".github","description":"profile","url":"https://github.com/acme-org/.github","primaryLanguage":null,"pushedAt":"2026-09-25T10:00:00Z","homepageUrl":""}]
JSON
cat > "$TMP/private.json" <<'JSON'
[{"name":"secret-widget","description":"An internal dashboard that tracks quarterly pledge totals by region"},
 {"name":"hidden-thing","description":""}]
JSON

new_repo(){
  R="$TMP/repo-$1"
  mkdir -p "$R/profile"
  cat > "$R/profile/README.md" <<'MD'
# Hello

Intro line stays.

<!-- BEGIN:public-repos -->
old table
<!-- END:public-repos -->

Footer stays.

<!-- last-refreshed: 2026-01-01 -->
MD
  git -C "$R" init -q
  git -C "$R" add -A
  git -C "$R" commit -qm init
}

leaks(){ python3 "$OP" check-leaks --org acme-org --root "$R" \
  --private-json "$TMP/private.json" --public-json "$TMP/public.json" "$@"; }

# --- render-public ---------------------------------------------------------
new_repo render
python3 "$OP" render-public --root "$R" --input "$TMP/public.json" >/dev/null 2>&1 \
  && ok || bad "render-public exited non-zero"
cp "$R/profile/README.md" "$TMP/first.md"
python3 "$OP" render-public --root "$R" --input "$TMP/public.json" >/dev/null 2>&1
cmp -s "$TMP/first.md" "$R/profile/README.md" && ok || bad "render-public is not idempotent"

grep -q '^Intro line stays\.$' "$R/profile/README.md" && grep -q '^Footer stays\.$' "$R/profile/README.md" \
  && ok || bad "text outside the markers changed"
grep -q 'old table' "$R/profile/README.md" && bad "old region content survived" || ok
grep -q '\.github' "$R/profile/README.md" && bad ".github was not excluded" || ok
grep -qF 'Does a \| thing' "$R/profile/README.md" && ok || bad "pipe in description not escaped"
grep -qF '([site](https://example.org))' "$R/profile/README.md" && ok || bad "homepage link missing"

# order: newest push first, ties broken by name
order="$(grep -o '^| \[[a-z-]*\]' "$R/profile/README.md" | tr -d '|[] ' | tr '\n' ',')"
[ "$order" = "secret-widget-docs,acme-tool,beta-tool," ] && ok || bad "wrong row order: $order"
grep -qF '| 2026-09-20 |' "$R/profile/README.md" && ok || bad "push date not YYYY-MM-DD"

# missing markers -> clear error, file untouched
printf '# no markers\n' > "$TMP/nomark.md"
out="$(python3 "$OP" render-public --readme "$TMP/nomark.md" --input "$TMP/public.json" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok || bad "missing markers exited 0"
case "$out" in *BEGIN:public-repos*) ok ;; *) bad "missing-marker error unclear: $out" ;; esac
[ "$(cat "$TMP/nomark.md")" = "# no markers" ] && ok || bad "README modified despite missing markers"

# --- check-leaks: clean tree ------------------------------------------------
new_repo clean
python3 "$OP" render-public --root "$R" --input "$TMP/public.json" >/dev/null 2>&1
printf 'See secret-widget-docs and https://github.com/acme-org/acme-tool.\n' >> "$R/profile/README.md"
git -C "$R" add -A
leaks >/dev/null 2>&1 && ok || bad "clean tree (hyphen-extended public name) flagged as a leak"

# --- leak in README ----------------------------------------------------------
new_repo readme
printf 'We also run Secret-Widget internally.\n' >> "$R/profile/README.md"
out="$(leaks --readme-only 2>"$TMP/err")"
rc=$?
[ "$rc" -eq 1 ] && ok || bad "README leak not detected (rc=$rc)"
case "$out" in *"profile/README.md:12: private repo name"*) ok ;; *) bad "README leak not reported as file:line: $out" ;; esac
case "$out" in *secret-widget*|*Secret-Widget*) bad "private name printed to stdout" ;; *) ok ;; esac
grep -q 'secret-widget' "$TMP/err" && ok || bad "private name not reported on stderr"

# --- leak in a tracked non-README file ---------------------------------------
new_repo tree
printf 'notes: secret-widget.\n' > "$R/notes.txt"
git -C "$R" add notes.txt && git -C "$R" commit -qm notes
out="$(leaks --tree 2>/dev/null)"
[ $? -eq 1 ] && ok || bad "tracked-file leak not detected"
case "$out" in *"notes.txt:1:"*) ok ;; *) bad "tracked-file leak not reported: $out" ;; esac

# staged-only file counts too
new_repo staged
printf 'hidden-thing\n' > "$R/staged.md"
git -C "$R" add staged.md
leaks --tree >/dev/null 2>&1; [ $? -eq 1 ] && ok || bad "staged-file leak not detected"

# untracked files are out of scope; binaries are skipped
new_repo scope
printf 'secret-widget\n' > "$R/untracked.txt"
printf 'secret-widget\0binary' > "$R/blob.bin"
git -C "$R" add blob.bin
leaks --tree >/dev/null 2>&1 && ok || bad "untracked or binary file was scanned"

# --- no false positive on hyphen-extended or embedded names ------------------
new_repo hyphen
printf 'secret-widget-docs, my-secret-widget, secret_widget2, xsecret-widget\n' >> "$R/profile/README.md"
git -C "$R" add -A
leaks >/dev/null 2>&1 && ok || bad "hyphen/underscore-extended name false-matched"

# --- link to a non-public repo ------------------------------------------------
new_repo link
printf 'See [x](https://github.com/acme-org/other-private) and acme-org/acme-tool and github.com/orgs/acme-org/people.\n' >> "$R/profile/README.md"
out="$(leaks --readme-only 2>"$TMP/err")"
[ $? -eq 1 ] && ok || bad "link to non-public repo not flagged"
case "$out" in *"link to non-public repo"*) ok ;; *) bad "link finding not labeled: $out" ;; esac
n="$(grep -c 'link to non-public repo' "$TMP/err")"
[ "$n" = "1" ] && ok || bad "expected exactly one link finding (public link or orgs/ path false-matched), got $n"

# --- 5-word description phrase --------------------------------------------------
new_repo phrase
printf 'We keep a dashboard that tracks quarterly\npledge totals for staff.\n' >> "$R/profile/README.md"
out="$(leaks --readme-only 2>/dev/null)"
[ $? -eq 1 ] && ok || bad "5-word private description phrase (across a line break) not flagged"
case "$out" in *"private description phrase"*) ok ;; *) bad "phrase finding not labeled: $out" ;; esac
new_repo phrase4
printf 'We track quarterly pledge totals.\n' >> "$R/profile/README.md"
leaks --readme-only >/dev/null 2>&1 && ok || bad "a 4-word overlap was flagged"

# --- --also scans an extra file (commit message) --------------------------------
new_repo also
printf 'fix: tidy hidden-thing refs\n' > "$TMP/msg.txt"
leaks --also "$TMP/msg.txt" >/dev/null 2>&1; [ $? -eq 1 ] && ok || bad "--also file not scanned"

# --- gh failure is an error, never a pass ----------------------------------------
new_repo gh
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho "HTTP 401" >&2\nexit 1\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
PATH="$TMP/bin:$PATH" python3 "$OP" check-leaks --root "$R" >/dev/null 2>&1
[ $? -eq 2 ] && ok || bad "gh failure did not exit 2"

# --- stamp -----------------------------------------------------------------------
new_repo stamp
python3 "$OP" stamp --root "$R" --date 2026-09-25 >/dev/null 2>&1
grep -qF '<!-- last-refreshed: 2026-09-25 -->' "$R/profile/README.md" && ok || bad "stamp not updated"
[ "$(grep -c 'last-refreshed' "$R/profile/README.md")" = "1" ] && ok || bad "stamp duplicated"
python3 "$OP" stamp --root "$R" --date 2026-13-40 >/dev/null 2>&1; [ $? -eq 2 ] && ok || bad "bad --date accepted"
printf '# bare\n' > "$TMP/bare.md"
python3 "$OP" stamp --readme "$TMP/bare.md" --date 2026-09-25 >/dev/null 2>&1
tail -1 "$TMP/bare.md" | grep -qF '<!-- last-refreshed: 2026-09-25 -->' && ok || bad "stamp not appended when absent"

# --- digest ----------------------------------------------------------------------
SD="$TMP/state"
python3 "$OP" digest --state-dir "$SD" --readme "$TMP/bare.md" >/dev/null 2>"$TMP/err"
[ $? -eq 2 ] && grep -q 'discover/profile first' "$TMP/err" && ok || bad "missing state not reported"

mkdir -p "$SD/profiles"
cat > "$SD/repos.json" <<'JSON'
[{"nwo":"acme-org/acme-tool","archived":false,"fork":false,"local_path":null,"description":"d","topics":["t"],"default_branch":"main","languages":{},"visibility":"public","pushed_at":"2026-09-30T00:00:00Z"},
 {"nwo":"acme-org/secret-widget","archived":false,"fork":false,"local_path":null,"description":null,"topics":[],"default_branch":"main","languages":{},"visibility":"private","pushed_at":"2026-09-01T00:00:00Z"},
 {"nwo":"someone/else","archived":false,"fork":false,"local_path":null,"description":null,"topics":[],"default_branch":"main","languages":{}}]
JSON
printf '{"nwo":"acme-org/acme-tool","readme_head":"# acme"}\n' > "$SD/profiles/acme-org__acme-tool.json"
python3 "$OP" digest --org acme-org --state-dir "$SD" --readme "$TMP/bare.md" >/dev/null 2>&1 \
  && ok || bad "digest failed on valid state"
D="$SD/org-profile-digest.json"
[ "$(jq '.repos | length' "$D")" = "2" ] && ok || bad "digest did not filter to the org"
[ "$(jq -r '.first_digest' "$D")" = "true" ] && ok || bad "first run not marked"
[ "$(jq -r '.repos[] | select(.nwo=="acme-org/acme-tool") | .flags.pushed_since_refresh' "$D")" = "true" ] \
  && ok || bad "pushed_since_refresh wrong for a later push"
[ "$(jq -r '.repos[] | select(.nwo=="acme-org/secret-widget") | .flags.pushed_since_refresh' "$D")" = "false" ] \
  && ok || bad "pushed_since_refresh wrong for an earlier push"
[ "$(jq -r '.repos[] | select(.nwo=="acme-org/acme-tool") | .readme_head' "$D")" = "# acme" ] \
  && ok || bad "readme_head not carried from profile"

# second run: one repo goes public->private, one archived, one new, one gone
cat > "$SD/repos.json" <<'JSON'
[{"nwo":"acme-org/acme-tool","archived":true,"fork":false,"description":"d","topics":[],"visibility":"private","pushed_at":"2026-09-30T00:00:00Z"},
 {"nwo":"acme-org/newbie","archived":false,"fork":false,"description":null,"topics":[],"visibility":"public","pushed_at":"2026-09-30T00:00:00Z"}]
JSON
python3 "$OP" digest --org acme-org --state-dir "$SD" --readme "$TMP/bare.md" >/dev/null 2>&1
q(){ jq -r "$1" "$D"; }
[ "$(q '.repos[] | select(.nwo=="acme-org/acme-tool") | .flags.visibility_changed')" = "true" ] \
  && ok || bad "visibility change not flagged"
[ "$(q '.repos[] | select(.nwo=="acme-org/acme-tool") | .flags.newly_archived')" = "true" ] \
  && ok || bad "newly archived not flagged"
[ "$(q '.repos[] | select(.nwo=="acme-org/newbie") | .flags.new_since_last_digest')" = "true" ] \
  && ok || bad "new repo not flagged"
[ "$(q '.missing_since_last_digest | join(",")')" = "acme-org/secret-widget" ] \
  && ok || bad "vanished repo not listed"
[ -f "$SD/org-profile-digest.prev.json" ] && ok || bad "previous digest not kept"

echo "org-profile: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "org-profile: PASS" || { echo "org-profile: FAIL"; exit 1; }
