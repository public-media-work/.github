#!/usr/bin/env python3
"""Write approved metadata back to GitHub.

Stage 4 of repo-meta, and the only code here that mutates anything. It reads
approvals.json and refuses anything else: a proposals file has a different
shape precisely so it cannot be passed by accident.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
from pathlib import Path

APPROVAL_KEYS = {"nwo", "add_topics", "remove_topics"}
README_BRANCH = "docs/add-readme"
README_TITLE = "docs: add README"
README_PR_BODY = """\
This README was drafted by repo-meta from this repository's own files (its \
tree, manifests, commit history and agent notes) and approved by a person at \
repo-meta's approval gate before this PR was opened.

The repository had no README. Nothing else is changed. Review it like any \
other change, then merge it, edit it, or close it.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
"""

sys.path.insert(0, str(Path(__file__).parent))
from suggest import fetch_private_names, readme_violations  # noqa: E402


def state_dir(override: str | None) -> Path:
    if override:
        return Path(override)
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "repo-meta"


def load_approvals(path: Path) -> list[dict]:
    data = json.loads(path.read_text())
    if not isinstance(data, list):
        raise SystemExit(f"{path}: expected a JSON array of approvals")
    for row in data:
        if not isinstance(row, dict) or not APPROVAL_KEYS <= set(row):
            raise SystemExit(
                f"{path}: not an approvals file — each row needs "
                f"{sorted(APPROVAL_KEYS)}. A proposals file is not accepted here; "
                f"approvals are produced by a human at the gate."
            )
    return data


def gh_edit(nwo: str, args: list[str]) -> tuple[bool, str]:
    proc = subprocess.run(["gh", "repo", "edit", nwo, *args],
                          capture_output=True, text=True)
    return proc.returncode == 0, proc.stderr.strip()[:300]


def gh(*args: str) -> tuple[int, str, str]:
    """One gh call. A timeout or a missing gh is rc -1, never an exception."""
    try:
        proc = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return -1, "", str(exc)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()[:300]


def is_404(err: str) -> bool:
    return "404" in err or "Not Found" in err


def readme_step(nwo: str, text: str, commit: bool,
                private_cache: dict[str, list[str] | None]) -> dict:
    """Open a PR adding README.md to a repo that has none. Never pushes to the
    default branch: the file goes to README_BRANCH and a person merges the PR.

    Returns the run-log record. Every failure is recorded, never raised.
    """
    rec: dict = {"nwo": nwo, "kind": "readme", "actions": [], "ok": False,
                 "error": None, "skipped": None, "pr_url": None}

    # The gh-free checks run before anything else, dry run included. The
    # private-name check needs gh, so it waits for --commit, below.
    bad = readme_violations(text, [], check_private=False)
    if bad:
        rec["error"] = "README fails validation: " + ", ".join(bad)
        return rec

    if not commit:
        lines = len(text.strip("\n").splitlines())
        print(f"DRY-RUN readme {nwo}: check README.md is still missing on the default "
              f"branch and that {README_BRANCH} and an open PR from it do not exist; "
              f"create {README_BRANCH} from the default branch head; PUT README.md "
              f"({lines} lines) on {README_BRANCH}; open a pull request "
              f"'{README_TITLE}' into the default branch")
        rec.update(ok=True, error="dry-run", actions=["plan"])
        return rec

    rc, out, err = gh("api", f"repos/{nwo}")
    if rc != 0:
        rec["error"] = f"repo lookup failed: {err}"
        return rec
    try:
        meta = json.loads(out)
        default = meta["default_branch"]
    except (json.JSONDecodeError, KeyError, TypeError):
        rec["error"] = "repo lookup returned no default branch"
        return rec
    if default == README_BRANCH:
        rec["error"] = "default branch is the README branch; refusing"
        return rec

    # Public repo: no private repo name of the same owner, checked against the
    # live list. suggest.py checked the draft; this checks what was approved.
    if str(meta.get("visibility") or "public").lower() != "private":
        owner = nwo.split("/")[0]
        if owner not in private_cache:
            private_cache[owner] = fetch_private_names(owner)
        bad = readme_violations(text, private_cache[owner], check_private=True)
        if bad:
            rec["error"] = "README fails validation: " + ", ".join(bad)
            return rec

    rc, _, err = gh("api", f"repos/{nwo}/readme?ref={default}")
    if rc == 0:
        rec["skipped"] = "a README now exists on the default branch"
        return rec
    if not is_404(err):
        rec["error"] = f"README check failed: {err}"
        return rec

    rc, _, err = gh("api", f"repos/{nwo}/git/ref/heads/{README_BRANCH}")
    if rc == 0:
        rec["skipped"] = f"branch {README_BRANCH} already exists"
        return rec
    if not is_404(err):
        rec["error"] = f"branch check failed: {err}"
        return rec

    rc, out, err = gh("pr", "list", "-R", nwo, "--head", README_BRANCH, "--state", "open",
                      "--json", "url", "-q", ".[].url")
    if rc != 0:
        rec["error"] = f"PR check failed: {err}"
        return rec
    if out:
        rec["skipped"] = f"an open PR from {README_BRANCH} already exists"
        rec["pr_url"] = out.splitlines()[0]
        return rec

    rc, sha, err = gh("api", f"repos/{nwo}/git/ref/heads/{default}", "-q", ".object.sha")
    if rc != 0 or not sha:
        rec["error"] = f"default branch head lookup failed: {err}"
        return rec
    rec["actions"].append(f"ref-get {default}@{sha}")

    rc, _, err = gh("api", "-X", "POST", f"repos/{nwo}/git/refs",
                    "-f", f"ref=refs/heads/{README_BRANCH}", "-f", f"sha={sha}")
    if rc != 0:
        rec["error"] = f"branch create failed: {err}"
        return rec
    rec["actions"].append(f"ref-create {README_BRANCH}")

    # -f sends the value as a string. The content is inline base64, never
    # "@file": with -f that would send the literal path.
    content = base64.b64encode(text.encode()).decode()
    rc, _, err = gh("api", "-X", "PUT", f"repos/{nwo}/contents/README.md",
                    "-f", f"message={README_TITLE}", "-f", f"content={content}",
                    "-f", f"branch={README_BRANCH}")
    if rc != 0:
        # Remove the branch this run just made, so a retry is not skipped as
        # "already exists". Only that branch: it was created a moment ago.
        gh("api", "-X", "DELETE", f"repos/{nwo}/git/refs/heads/{README_BRANCH}")
        rec["error"] = f"README write failed: {err}"
        return rec
    rec["actions"].append(f"put README.md on {README_BRANCH}")

    rc, out, err = gh("pr", "create", "-R", nwo, "--head", README_BRANCH, "--base", default,
                      "--title", README_TITLE, "--body", README_PR_BODY)
    if rc != 0:
        rec["error"] = (f"README is on {README_BRANCH} but the PR was not opened; "
                        f"open it by hand: {err}")
        return rec
    rec["actions"].append("pr create")
    rec["pr_url"] = out.splitlines()[-1] if out else None
    rec["ok"] = True
    return rec


def main() -> int:
    ap = argparse.ArgumentParser(description="Apply approved repo metadata.")
    ap.add_argument("--approvals", required=True)
    ap.add_argument("--state-dir", default=None)
    ap.add_argument("--commit", action="store_true",
                    help="actually write; omit for a dry run")
    args = ap.parse_args()

    approvals = load_approvals(Path(args.approvals))
    runs = state_dir(args.state_dir) / "runs"
    runs.mkdir(parents=True, exist_ok=True)
    # Second granularity plus mode "w" meant two --commit runs in the same second
    # silently truncated the first one's log. This is the audit trail for writes to
    # GitHub — the one artifact proving what was changed and under whose approval —
    # so losing it quietly is the worst available failure. "x" refuses to clobber,
    # and a counter suffix finds the next free name rather than erroring at the user.
    stamp = time.strftime("%Y%m%dT%H%M%S")
    log = runs / f"{stamp}.jsonl"
    dup = 1
    while log.exists():
        log = runs / f"{stamp}-{dup}.jsonl"
        dup += 1

    written = 0
    readme_prs = 0
    private_cache: dict[str, list[str] | None] = {}
    with log.open("x") as handle:
        for row in approvals:
            nwo = row["nwo"]
            # The README has its own approval key. Approving the description or
            # topics never approves a README, and only literal true counts.
            text = row.get("readme_markdown")
            if row.get("readme") is True and isinstance(text, str):
                rec = readme_step(nwo, text, args.commit, private_cache)
                if rec["skipped"]:
                    print(f"skip readme {nwo}: {rec['skipped']}", file=sys.stderr)
                elif rec["error"] and rec["error"] != "dry-run":
                    print(f"skip readme {nwo}: {rec['error']}", file=sys.stderr)
                elif rec["pr_url"]:
                    readme_prs += 1
                    print(f"opened {rec['pr_url']}")
                handle.write(json.dumps(rec) + "\n")

            desc = row.get("description")
            add = [t for t in (row.get("add_topics") or []) if t]
            remove = [t for t in (row.get("remove_topics") or []) if t]

            planned: list[str] = []
            # current_description is NOT in APPROVAL_KEYS, so a spec-conformant
            # approvals.json can legally omit it — and row.get() would then return
            # None, making `desc != None` true and re-writing an identical
            # description on every run. The skip existed but could not fire for a
            # file that followed the documented interface. When the field is absent
            # we ask GitHub instead of assuming a difference; the read is one call
            # and only happens for rows that propose a description at all.
            #
            # The probe runs on --commit only: a dry run issues no gh calls at all,
            # so without current_description it may list a description edit that
            # --commit then skips as a no-op.
            current = row.get("current_description")
            if desc and current is None and args.commit:
                try:
                    probe = subprocess.run(
                        ["gh", "repo", "view", nwo, "--json", "description",
                         "-q", ".description"],
                        capture_output=True, text=True, timeout=60,
                    )
                except (subprocess.TimeoutExpired, OSError):
                    probe = None
                if probe and probe.returncode == 0:
                    current = probe.stdout.strip()
            if desc and desc != current:
                planned += ["--description", desc]
            if add:
                planned += ["--add-topic", ",".join(add)]
            for topic in remove:
                planned += ["--remove-topic", topic]

            if not planned:
                handle.write(json.dumps({"nwo": nwo, "actions": [],
                                         "ok": True, "error": None}) + "\n")
                continue

            if not args.commit:
                print(f"DRY-RUN gh repo edit {nwo} {' '.join(planned)}")
                handle.write(json.dumps({"nwo": nwo, "actions": planned,
                                         "ok": True, "error": "dry-run"}) + "\n")
                continue

            ok, err = gh_edit(nwo, planned)
            written += 1 if ok else 0
            if not ok:
                print(f"skip {nwo}: {err}", file=sys.stderr)
            handle.write(json.dumps({"nwo": nwo, "actions": planned,
                                     "ok": ok, "error": err or None}) + "\n")

    mode = "wrote" if args.commit else "planned"
    print(f"{mode} {written if args.commit else len(approvals)} repos; "
          f"{readme_prs} README PRs opened; log: {log}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
