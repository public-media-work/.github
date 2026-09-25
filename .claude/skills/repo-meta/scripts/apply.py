#!/usr/bin/env python3
"""Write approved metadata back to GitHub.

Stage 4 of repo-meta, and the only code here that mutates anything. It reads
approvals.json and refuses anything else: a proposals file has a different
shape precisely so it cannot be passed by accident.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

APPROVAL_KEYS = {"nwo", "add_topics", "remove_topics"}


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
    with log.open("x") as handle:
        for row in approvals:
            nwo = row["nwo"]
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
    print(f"{mode} {written if args.commit else len(approvals)} repos; log: {log}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
