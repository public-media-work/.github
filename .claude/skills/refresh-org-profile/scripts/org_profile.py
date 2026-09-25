#!/usr/bin/env python3
"""Deterministic half of refresh-org-profile.

Subcommands:
  render-public  rewrite the public-repos table in profile/README.md
  digest         summarize repo-meta state for the capabilities redraft
  check-leaks    fail if a private repo name or description phrase is present
  stamp          set the last-refreshed date

This repo is PUBLIC. Nothing here writes private data into it: digest output
goes to the state dir, and check-leaks prints private names to stderr only.
Stdlib only; talks to GitHub through the `gh` CLI.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ORG_DEFAULT = "public-media-work"
README_DEFAULT = "profile/README.md"
PUBLIC_BEGIN = "<!-- BEGIN:public-repos -->"
PUBLIC_END = "<!-- END:public-repos -->"
STAMP_RE = re.compile(r"<!-- last-refreshed: (\d{4}-\d{2}-\d{2}|[^>]*?) -->")
DIGEST_NAME = "org-profile-digest.json"
PHRASE_WORDS = 5
# A name only matches when it is not part of a longer identifier. `-` counts as
# part of the word, so private `widget` does not match inside public
# `widget-docs`, and a real leak is not hidden inside a longer name either.
WORDCHARS = "A-Za-z0-9_-"


class Fail(Exception):
    """A user-facing error: printed without a traceback, exit 2."""


# --- shared helpers ---------------------------------------------------------

def gh_json(args: list[str]) -> list[dict]:
    try:
        proc = subprocess.run(["gh", *args], capture_output=True, text=True)
    except OSError as exc:
        raise Fail(f"could not run gh: {exc}")
    if proc.returncode != 0:
        raise Fail(f"gh {' '.join(args[:3])} failed: {proc.stderr.strip()[:300]}")
    try:
        data = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError as exc:
        raise Fail(f"gh returned unparseable JSON: {exc}")
    if not isinstance(data, list):
        raise Fail("gh returned JSON that is not a list")
    return data


def load_json_list(path: str) -> list[dict]:
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise Fail(f"cannot read {path}: {exc}")
    if not isinstance(data, list):
        raise Fail(f"{path}: expected a JSON array")
    return data


def repo_root(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    proc = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True)
    if proc.returncode == 0 and proc.stdout.strip():
        return Path(proc.stdout.strip())
    return Path.cwd()


def readme_path(args: argparse.Namespace) -> Path:
    p = Path(args.readme)
    return p if p.is_absolute() else repo_root(args.root) / p


def read_text(path: Path) -> str:
    try:
        return path.read_text()
    except OSError as exc:
        raise Fail(f"cannot read {path}: {exc}")


def state_dir(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit)
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "repo-meta"


# --- render-public ----------------------------------------------------------

def cell(text: str | None) -> str:
    text = " ".join((text or "").split())
    return text.replace("|", "\\|")


def render_table(repos: list[dict]) -> str:
    rows = [r for r in repos if r.get("name") and r.get("name") != ".github"]
    # Two stable sorts: name ascending, then most recent push first. Ties on
    # pushedAt keep name order, so identical input always renders identically.
    rows.sort(key=lambda r: r["name"].lower())
    rows.sort(key=lambda r: r.get("pushedAt") or "", reverse=True)
    if not rows:
        return "_No public repositories yet._"
    lines = ["| Repository | Description | Language | Last push |",
             "|---|---|---|---|"]
    for r in rows:
        lang = (r.get("primaryLanguage") or {}).get("name") or ""
        desc = cell(r.get("description"))
        home = (r.get("homepageUrl") or "").strip()
        if home:
            desc = f"{desc} ([site]({home}))" if desc else f"[site]({home})"
        pushed = (r.get("pushedAt") or "")[:10]
        lines.append(f"| [{r['name']}]({r.get('url', '')}) | {desc} | {cell(lang)} | {pushed} |")
    return "\n".join(lines)


def replace_region(text: str, begin: str, end: str, body: str) -> str:
    b, e = text.count(begin), text.count(end)
    if b != 1 or e != 1:
        raise Fail(f"expected exactly one {begin} and one {end} marker "
                   f"(found {b} and {e}); add them to the README first")
    start = text.index(begin) + len(begin)
    stop = text.index(end)
    if stop < start:
        raise Fail(f"{end} appears before {begin}")
    return text[:start] + "\n" + body + "\n" + text[stop:]


def cmd_render_public(args: argparse.Namespace) -> int:
    if args.input:
        repos = load_json_list(args.input)
    else:
        repos = gh_json(["repo", "list", args.org, "--visibility", "public",
                         "--no-archived", "--source", "--limit", "200", "--json",
                         "name,description,url,primaryLanguage,pushedAt,homepageUrl"])
    path = readme_path(args)
    old = read_text(path)
    new = replace_region(old, PUBLIC_BEGIN, PUBLIC_END, render_table(repos))
    if new == old:
        print(f"render-public: unchanged ({path})")
    else:
        path.write_text(new)
        print(f"render-public: updated {path}")
    return 0


# --- digest -----------------------------------------------------------------

def read_stamp(text: str) -> str | None:
    m = STAMP_RE.search(text)
    return m.group(1) if m and re.fullmatch(r"\d{4}-\d{2}-\d{2}", m.group(1)) else None


def visibility_of(row: dict) -> str | None:
    v = row.get("visibility")
    if isinstance(v, str) and v:
        return v.lower()
    if isinstance(row.get("private"), bool):
        return "private" if row["private"] else "public"
    return None


def cmd_digest(args: argparse.Namespace) -> int:
    sd = state_dir(args.state_dir)
    repos_file = sd / "repos.json"
    profiles = sd / "profiles"
    if not repos_file.is_file() or not profiles.is_dir():
        raise Fail(f"repo-meta state not found in {sd} "
                   "(run repo-meta discover/profile first)")
    rows = [r for r in load_json_list(str(repos_file))
            if str(r.get("nwo", "")).lower().startswith(args.org.lower() + "/")]

    readme = readme_path(args)
    stamp = read_stamp(read_text(readme)) if readme.is_file() else None

    out = Path(args.out) if args.out else sd / DIGEST_NAME
    prev: dict[str, dict] = {}
    had_prev = out.is_file()
    if had_prev:
        try:
            for r in json.loads(out.read_text()).get("repos", []):
                prev[r["nwo"]] = r
        except (OSError, json.JSONDecodeError, AttributeError, KeyError, TypeError):
            print(f"warn: previous digest {out} unreadable; treating as first run",
                  file=sys.stderr)
            had_prev = False

    missing_fields = False
    entries = []
    for r in sorted(rows, key=lambda r: r["nwo"]):
        nwo = r["nwo"]
        prof: dict = {}
        pf = profiles / (nwo.replace("/", "__") + ".json")
        if pf.is_file():
            try:
                prof = json.loads(pf.read_text())
            except (OSError, json.JSONDecodeError):
                prof = {}
        vis = visibility_of(r)
        pushed = r.get("pushed_at") or r.get("pushedAt")
        if vis is None or pushed is None:
            missing_fields = True
        before = prev.get(nwo)
        archived = bool(r.get("archived"))
        entries.append({
            "nwo": nwo,
            "visibility": vis,
            "archived": archived,
            "pushed_at": pushed,
            "description": r.get("description"),
            "topics": r.get("topics") or [],
            "readme_head": prof.get("readme_head", ""),
            "flags": {
                "pushed_since_refresh": (pushed[:10] >= stamp) if (pushed and stamp) else None,
                "new_since_last_digest": bool(had_prev and before is None),
                "newly_archived": bool(archived and not (before or {}).get("archived", False)),
                "visibility_changed": (
                    bool(before and vis and before.get("visibility")
                         and before["visibility"] != vis)
                    if before else False
                ),
            },
        })

    current = {e["nwo"] for e in entries}
    digest = {
        "org": args.org,
        "generated": dt.date.today().isoformat(),
        "last_refreshed": stamp,
        "first_digest": not had_prev,
        # discover.py drops archived repos by default, so a repo that vanished
        # was archived, deleted, or filtered out; the digest cannot tell which.
        "missing_since_last_digest": sorted(n for n in prev if n not in current),
        "repos": entries,
    }
    if missing_fields:
        print("warn: repos.json lacks visibility and/or pushed_at for some repos; "
              "those flags are null", file=sys.stderr)
    out.parent.mkdir(parents=True, exist_ok=True)
    if had_prev:
        (out.parent / (out.stem + ".prev.json")).write_text(out.read_text())
    out.write_text(json.dumps(digest, indent=2) + "\n")
    flagged = sum(1 for e in entries if any(e["flags"].values()))
    print(f"digest: {len(entries)} repos, {flagged} flagged -> {out}")
    return 0


# --- check-leaks ------------------------------------------------------------

def name_pattern(name: str) -> re.Pattern:
    return re.compile(rf"(?<![{WORDCHARS}]){re.escape(name)}(?![{WORDCHARS}])",
                      re.IGNORECASE)


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", text.lower())


def tracked_files(root: Path) -> list[str]:
    names: set[str] = set()
    for cmd in (["ls-files"], ["diff", "--cached", "--name-only"]):
        proc = subprocess.run(["git", "-C", str(root), *cmd],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            raise Fail(f"git {' '.join(cmd)} failed in {root}: {proc.stderr.strip()[:200]}")
        names.update(n for n in proc.stdout.splitlines() if n)
    return sorted(names)


def read_if_text(path: Path) -> str | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None  # staged deletion, dangling symlink
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", errors="replace")


def scan_names(label: str, text: str, pats: list[tuple[str, re.Pattern]],
               found: list[tuple[str, int, str, str]]) -> None:
    for n, line in enumerate(text.splitlines(), 1):
        for name, pat in pats:
            if pat.search(line):
                found.append((label, n, "private repo name", name))


def scan_phrases(label: str, text: str, grams: dict[tuple[str, ...], str],
                 found: list[tuple[str, int, str, str]]) -> None:
    toks: list[tuple[str, int]] = []
    for n, line in enumerate(text.splitlines(), 1):
        toks.extend((w, n) for w in words(line))
    for i in range(len(toks) - PHRASE_WORDS + 1):
        key = tuple(w for w, _ in toks[i:i + PHRASE_WORDS])
        if key in grams:
            found.append((label, toks[i][1], "private description phrase",
                          f"{grams[key]}: \"{' '.join(key)}\""))


def scan_links(label: str, text: str, org: str, public: set[str],
               found: list[tuple[str, int, str, str]]) -> None:
    pat = re.compile(rf"(?:github\.com/|(?<![A-Za-z0-9_./-])){re.escape(org)}/([A-Za-z0-9._-]+)",
                     re.IGNORECASE)
    for n, line in enumerate(text.splitlines(), 1):
        for m in pat.finditer(line):
            x = m.group(1)
            cands = {x.lower(), x.rstrip(".").lower(),
                     re.sub(r"\.git$", "", x.rstrip(".")).lower()}
            if not cands & public:
                found.append((label, n, "link to non-public repo", x))


def cmd_check_leaks(args: argparse.Namespace) -> int:
    root = repo_root(args.root)
    if args.private_json:
        private = load_json_list(args.private_json)
    else:
        # Archived private repos are still private, so no --no-archived here.
        private = gh_json(["repo", "list", args.org, "--visibility", "private",
                           "--limit", "1000", "--json", "name,description"])
    if args.public_json:
        public_rows = load_json_list(args.public_json)
    else:
        public_rows = gh_json(["repo", "list", args.org, "--visibility", "public",
                               "--limit", "1000", "--json", "name"])
    public = {str(r.get("name", "")).lower() for r in public_rows if r.get("name")}

    pats = [(r["name"], name_pattern(r["name"])) for r in private if r.get("name")]
    grams: dict[tuple[str, ...], str] = {}
    for r in private:
        w = words(r.get("description") or "")
        for i in range(len(w) - PHRASE_WORDS + 1):
            grams.setdefault(tuple(w[i:i + PHRASE_WORDS]), r.get("name", "?"))

    do_readme = args.readme_only or not args.tree_only
    do_tree = args.tree_only or not args.readme_only
    found: list[tuple[str, int, str, str]] = []
    scanned = 0

    readme = readme_path(args)
    readme_label = os.path.relpath(readme, root)
    if do_readme:
        text = read_text(readme)
        scanned += 1
        scan_names(readme_label, text, pats, found)
        scan_phrases(readme_label, text, grams, found)
        scan_links(readme_label, text, args.org, public, found)
    if do_tree:
        for rel in tracked_files(root):
            if do_readme and rel == readme_label:
                continue
            text = read_if_text(root / rel)
            if text is None:
                continue
            scanned += 1
            scan_names(rel, text, pats, found)
    for extra in args.also or []:
        text = read_text(Path(extra))
        scanned += 1
        scan_names(extra, text, pats, found)
        scan_phrases(extra, text, grams, found)

    found = sorted(set(found))
    if not found:
        print(f"check-leaks: clean ({scanned} files, {len(pats)} private names)")
        return 0
    for label, line, kind, detail in found:
        # The private detail goes to stderr only, so a captured stdout (a log,
        # a PR comment) never carries the name it is warning about.
        print(f"{label}:{line}: {kind}", file=sys.stdout)
        print(f"  {label}:{line}: {kind}: {detail}", file=sys.stderr)
    print(f"check-leaks: FAIL ({len(found)} finding(s)); fix before committing",
          file=sys.stdout)
    return 1


# --- stamp ------------------------------------------------------------------

def cmd_stamp(args: argparse.Namespace) -> int:
    date = args.date or dt.date.today().isoformat()
    try:
        dt.date.fromisoformat(date)
    except ValueError:
        raise Fail(f"--date must be YYYY-MM-DD, got {date!r}")
    path = readme_path(args)
    old = read_text(path)
    marker = f"<!-- last-refreshed: {date} -->"
    if STAMP_RE.search(old):
        new = STAMP_RE.sub(marker, old, count=1)
    else:
        new = old.rstrip("\n") + "\n\n" + marker + "\n"
    if new != old:
        path.write_text(new)
    print(f"stamp: {date} -> {path}")
    return 0


# --- cli --------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--org", default=ORG_DEFAULT)
    common.add_argument("--readme", default=README_DEFAULT,
                        help="relative paths resolve against --root")
    common.add_argument("--root", default=None,
                        help="repo root (default: git toplevel of cwd)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("render-public", parents=[common])
    p.add_argument("--input", help="render from saved gh JSON instead of the network")
    p.set_defaults(func=cmd_render_public)

    p = sub.add_parser("digest", parents=[common])
    p.add_argument("--state-dir", default=None)
    p.add_argument("--out", default=None, help=f"default: <state-dir>/{DIGEST_NAME}")
    p.set_defaults(func=cmd_digest)

    p = sub.add_parser("check-leaks", parents=[common])
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--readme-only", dest="readme_only", action="store_true",
                      help="check only the README")
    mode.add_argument("--tree-only", "--tree", dest="tree_only", action="store_true",
                      help="check only tracked + staged files for names")
    p.add_argument("--also", action="append", metavar="FILE",
                   help="also scan FILE (a commit message, a PR body); repeatable")
    p.add_argument("--private-json", help="private repo list (name, description)")
    p.add_argument("--public-json", help="public repo list (name)")
    p.set_defaults(func=cmd_check_leaks)

    p = sub.add_parser("stamp", parents=[common])
    p.add_argument("--date", default=None)
    p.set_defaults(func=cmd_stamp)

    args = ap.parse_args()
    try:
        return args.func(args)
    except Fail as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
