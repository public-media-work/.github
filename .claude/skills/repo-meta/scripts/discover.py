#!/usr/bin/env python3
"""Resolve the repo set: GitHub metadata joined against local checkouts.

Stage 1 of repo-meta. Network only — reads no file contents. Emits repos.json,
the primary key for every later stage.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

WORKSPACE_DEFAULT = Path.home() / "Developer"


class RateLimited(RuntimeError):
    """The API refused for quota reasons — retryable, and never silently empty."""


def gh_json(path: str, required: bool = False,
            attempts: int = int(os.environ.get("REPO_META_GH_ATTEMPTS", "4"))) -> list[dict]:
    """Call `gh api --paginate <path>`; back off on rate limits.

    An empty list is a real answer (an org with no repos) and a rate-limited
    call is not. Conflating them is how a throttled run emits a short
    repos.json that looks successful — so a required path raises instead.
    """
    delay = 5
    for attempt in range(attempts):
        proc = subprocess.run(
            ["gh", "api", "--paginate", path],
            capture_output=True, text=True,
        )
        if proc.returncode == 0:
            break
        err = proc.stderr.strip()
        throttled = ("rate limit" in err.lower()
                     or "secondary rate" in err.lower()
                     or "403" in err and "abuse" in err.lower())
        if throttled and attempt < attempts - 1:
            print(f"rate limited on {path}; retrying in {delay}s "
                  f"({attempt + 1}/{attempts - 1})", file=sys.stderr)
            time.sleep(delay)
            delay *= 2
            continue
        if required:
            raise RateLimited(f"gh api {path} failed after {attempt + 1} attempt(s): {err[:200]}")
        print(f"warn: gh api {path} failed: {err[:200]}", file=sys.stderr)
        return []
    out = proc.stdout.strip()
    if not out:
        return []
    # --paginate concatenates arrays as separate documents in some gh versions.
    try:
        data = json.loads(out)
        return data if isinstance(data, list) else [data]
    except json.JSONDecodeError:
        merged: list[dict] = []
        decoder = json.JSONDecoder()
        idx = 0
        while idx < len(out):
            while idx < len(out) and out[idx].isspace():
                idx += 1
            if idx >= len(out):
                break
            chunk, idx = decoder.raw_decode(out, idx)
            merged.extend(chunk if isinstance(chunk, list) else [chunk])
        return merged


def local_checkouts(workspace: Path) -> dict[str, str]:
    """Map owner/repo -> checkout path for every git repo under workspace.

    -type d matters: a worktree's or submodule's .git is a FILE, so this
    naturally counts only real checkouts.
    """
    found: dict[str, str] = {}
    if not workspace.is_dir():
        return found
    proc = subprocess.run(
        ["find", str(workspace), "-maxdepth", "4", "-name", ".git", "-type", "d"],
        capture_output=True, text=True,
    )
    for line in proc.stdout.splitlines():
        repo_dir = Path(line).parent
        if "/Backups/" in f"{repo_dir}/":
            continue
        url = subprocess.run(
            ["git", "-C", str(repo_dir), "remote", "get-url", "origin"],
            capture_output=True, text=True,
        ).stdout.strip()
        if "github.com" not in url:
            continue
        tail = url.split("github.com", 1)[1].lstrip(":/")
        if tail.endswith(".git"):
            tail = tail[:-4]
        parts = tail.split("/")
        if len(parts) < 2:
            continue
        nwo = f"{parts[0]}/{parts[1]}"
        # Two checkouts of one repo: prefer the shallower path, then the
        # lexicographically smaller one. setdefault alone let filesystem traversal
        # order decide, so which checkout got profiled could change between runs on
        # the same machine with nothing having changed.
        cand = str(repo_dir)
        prev = found.get(nwo)
        if prev is None or (cand.count(os.sep), cand) < (prev.count(os.sep), prev):
            found[nwo] = cand
    return found


def row(raw: dict, checkouts: dict[str, str]) -> dict:
    nwo = raw.get("full_name", "")
    return {
        "nwo": nwo,
        "archived": bool(raw.get("archived")),
        "fork": bool(raw.get("fork")),
        "local_path": checkouts.get(nwo),
        "description": raw.get("description"),
        "topics": raw.get("topics") or [],
        "default_branch": raw.get("default_branch") or "main",
        # GitHub's repo-LIST endpoint returns `language` — a single string, the
        # primary language — and never a `languages` map; the byte-count map is a
        # separate call to `languages_url`. Reading "languages" here yielded {}
        # for every repo, and because profile.py and suggest.py both read this
        # field to shape their output, the failure was a silent quality loss
        # rather than an error: descriptions got written with no language signal
        # at all and nothing said so.
        #
        # Populating from the singular field keeps the declared {str: int} shape
        # with a count of 1, which downstream code already tolerates. A true
        # byte-count breakdown needs one extra GET per repo against
        # languages_url; deferred deliberately rather than silently, because it
        # multiplies the API budget by the repo count for a signal that only
        # refines wording.
        "languages": ({raw["language"]: 1} if raw.get("language") else {}),
    }


def main() -> int:
    try:
        return _main()
    except RateLimited as exc:
        print(f"error: {exc}", file=sys.stderr)
        print("nothing written — a partial repo set would look like a complete one",
              file=sys.stderr)
        return 1


def _main() -> int:
    ap = argparse.ArgumentParser(description="Resolve the repo set for repo-meta.")
    ap.add_argument("--workspace", default=str(WORKSPACE_DEFAULT))
    ap.add_argument("--out", required=True)
    ap.add_argument("--include-archived", action="store_true")
    ap.add_argument("--include-forks", action="store_true")
    ap.add_argument("--only-local", action="store_true")
    ap.add_argument("--repo", help="single owner/repo; skips discovery")
    ap.add_argument("--org", action="append", default=None,
                    help="limit to these orgs (repeatable); default is all")
    args = ap.parse_args()

    try:
        checkouts = local_checkouts(Path(args.workspace))
    except OSError as exc:
        raise SystemExit(f"workspace scan failed: {exc}")

    raws: list[dict] = []
    if args.repo:
        raws = gh_json(f"/repos/{args.repo}", required=True)
    else:
        # --org is a limit, not an addition: an org-scoped run must not sweep in
        # the operator's personal repos, so /user/repos is only listed without it.
        if not args.org:
            raws.extend(gh_json("/user/repos?per_page=100&affiliation=owner", required=True))
        # required=True on both org calls. The docstring already says an empty list
        # is a real answer and a throttled call is not — but only /user/repos was
        # marked required, so a rate-limited /user/orgs silently yielded "you are in
        # no orgs" and a throttled /orgs/X/repos silently yielded "that org has no
        # repos". Either way the run exits 0 with a short repos.json that looks
        # complete, which is the exact failure the required flag exists to prevent.
        orgs = args.org or [o.get("login")
                            for o in gh_json("/user/orgs", required=True)
                            if o.get("login")]
        for org in orgs:
            raws.extend(gh_json(f"/orgs/{org}/repos?per_page=100", required=True))

    seen: set[str] = set()
    rows: list[dict] = []
    for raw in raws:
        r = row(raw, checkouts)
        if not r["nwo"] or r["nwo"] in seen:
            continue
        # --repo names ONE repo explicitly, which is already the operator saying they
        # want it. Running it through the archived/fork filters meant naming an
        # archived or forked repo produced an empty repos.json and exit 0 — the
        # shape that reads as "nothing to do" rather than "I dropped what you asked
        # for". The filters exist to trim a bulk listing, not to overrule a name.
        if not args.repo and r["archived"] and not args.include_archived:
            continue
        if not args.repo and r["fork"] and not args.include_forks:
            continue
        if args.only_local and not r["local_path"]:
            continue
        seen.add(r["nwo"])
        rows.append(r)

    rows.sort(key=lambda r: r["nwo"])
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(rows, indent=2) + "\n")
    print(f"discovered {len(rows)} repos -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
