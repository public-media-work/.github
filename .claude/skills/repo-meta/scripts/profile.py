#!/usr/bin/env python3
"""Build the per-repo evidence pack — the deterministic half of the pipeline.

Stage 2 of repo-meta. Reads a local checkout where one exists, otherwise
shallow-clones into a temp dir and deletes it. No model calls. Cached by
commit sha so re-running a later stage never re-clones.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

README_CAP = 2000
TREE_CAP = 60
COMMIT_CAP = 10
MANIFESTS = ("package.json", "pyproject.toml", "Cargo.toml", "go.mod",
             "Gemfile", "composer.json")
SIGNAL_PATHS = {
    "dockerfile": "Dockerfile",
    "github_workflows": ".github/workflows",
    "skill": "SKILL.md",
    "claude_plugin": ".claude-plugin",
    "adr": "docs/adr",
}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args],
                          capture_output=True, text=True).stdout.strip()


def read_readme(root: Path) -> str:
    for p in sorted(root.glob("README*")):
        if p.is_file():
            try:
                return p.read_text(errors="replace")[:README_CAP]
            except OSError:
                continue
    return ""


def read_manifests(root: Path) -> dict[str, dict]:
    found: dict[str, dict] = {}
    for name in MANIFESTS:
        p = root / name
        if not p.is_file():
            continue
        try:
            text = p.read_text(errors="replace")
        except OSError:
            continue
        if name == "package.json":
            try:
                raw = json.loads(text)
                found[name] = {
                    "name": raw.get("name"),
                    "description": raw.get("description"),
                    "dependencies": sorted((raw.get("dependencies") or {}).keys())[:25],
                }
            except json.JSONDecodeError:
                found[name] = {"unparsed": True}
        else:
            # Keep it dumb and dependency-free: the first 40 lines carry the
            # name/description/deps for every format we care about.
            found[name] = {"head": "\n".join(text.splitlines()[:40])}
    return found


def build_tree(root: Path) -> list[str]:
    entries: list[str] = []
    for child in sorted(root.iterdir()):
        if child.name == ".git":
            continue
        if child.is_dir():
            entries.append(f"{child.name}/")
            for grand in sorted(child.iterdir()):
                if len(entries) >= TREE_CAP:
                    return entries
                entries.append(f"{child.name}/{grand.name}" + ("/" if grand.is_dir() else ""))
        else:
            entries.append(child.name)
        if len(entries) >= TREE_CAP:
            break
    return entries[:TREE_CAP]


def detect_signals(root: Path) -> dict[str, bool]:
    return {key: (root / rel).exists() for key, rel in SIGNAL_PATHS.items()}


def profile_root(root: Path, repo: dict, source: str) -> dict:
    return {
        "nwo": repo["nwo"],
        "source": source,
        "sha": git(root, "rev-parse", "HEAD") or None,
        "readme_head": read_readme(root),
        "manifests": read_manifests(root),
        "tree": build_tree(root),
        "languages": repo.get("languages") or {},
        "recent_commits": [
            line for line in
            git(root, "log", f"-{COMMIT_CAP}", "--format=%s").splitlines() if line
        ],
        "current": {
            "description": repo.get("description"),
            "topics": repo.get("topics") or [],
        },
        "signals": detect_signals(root),
    }


def clone_url(nwo: str, template: str | None) -> str:
    # The template exists so tests can point origin at a local dir; git clones
    # file-to-file, which exercises the real --depth=1 path with no network.
    return template if template else f"https://github.com/{nwo}.git"


def main() -> int:
    ap = argparse.ArgumentParser(description="Build repo-meta evidence packs.")
    ap.add_argument("--repos", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--clone-url-template", default=None)
    ap.add_argument("--force", action="store_true", help="ignore the sha cache")
    args = ap.parse_args()

    repos = json.loads(Path(args.repos).read_text())
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    errors: dict[str, str] = {}

    for repo in repos:
        nwo = repo["nwo"]
        dest = out / (nwo.replace("/", "__") + ".json")
        local = repo.get("local_path")

        if local and Path(local).is_dir():
            root = Path(local)
            if dest.exists() and not args.force:
                try:
                    cached = json.loads(dest.read_text()).get("sha")
                    if cached and cached == git(root, "rev-parse", "HEAD"):
                        continue
                except (json.JSONDecodeError, OSError):
                    pass
            try:
                dest.write_text(json.dumps(profile_root(root, repo, "local"), indent=2) + "\n")
            except OSError as exc:
                errors[nwo] = f"local read failed: {exc}"
            continue

        # The local branch above skips when the cached sha still matches HEAD. The
        # clone branch had no equivalent, so every run re-cloned every checkout-less
        # repo — the caching invariant this plan states held for exactly half the
        # repos, and the half it missed is the expensive one. ls-remote asks the
        # remote for the same sha without fetching a tree.
        if dest.exists() and not args.force:
            try:
                cached = json.loads(dest.read_text()).get("sha")
            except (json.JSONDecodeError, OSError):
                cached = None
            if cached:
                try:
                    ls = subprocess.run(
                        ["git", "ls-remote", clone_url(nwo, args.clone_url_template), "HEAD"],
                        capture_output=True, text=True, timeout=60,
                    )
                except (subprocess.TimeoutExpired, OSError):
                    ls = None
                head = ls.stdout.split("\t", 1)[0].strip() if ls and ls.returncode == 0 else ""
                if head and head == cached:
                    continue

        tmp = Path(tempfile.mkdtemp(prefix="repo-meta-"))
        try:
            proc = subprocess.run(
                ["git", "clone", "--depth=1", "--filter=blob:none", "--quiet",
                 clone_url(nwo, args.clone_url_template), str(tmp / "r")],
                capture_output=True, text=True,
                # A stalled clone with no timeout hangs the whole batch, and the batch
                # is every repo in the account. 300s is generous for --depth=1
                # --filter=blob:none and still bounded.
                timeout=300,
            )
            if proc.returncode != 0:
                errors[nwo] = f"clone failed: {proc.stderr.strip()[:200]}"
                continue
            dest.write_text(json.dumps(profile_root(tmp / "r", repo, "clone"), indent=2) + "\n")
        # TimeoutExpired is not an OSError, so catching only OSError would let the
        # timeout added above crash the batch it exists to protect. Same pairing
        # the local-model call already uses.
        except (subprocess.TimeoutExpired, OSError) as exc:
            errors[nwo] = f"clone error: {exc}"
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    (out / "_errors.json").write_text(json.dumps(errors, indent=2) + "\n")
    print(f"profiled {len(repos) - len(errors)} repos, {len(errors)} errors -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
