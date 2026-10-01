#!/usr/bin/env python3
"""Propose descriptions and topics, then validate whatever was proposed.

Stage 3 of repo-meta. The writer is pluggable (--engine local|agent|none); the
VALIDATOR is not — every proposal passes through it regardless of origin, so a
model's output is held to the same bar as a deterministic one.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

DESC_TARGET = 120
DESC_HARD = 350
TOPIC_MIN, TOPIC_MAX = 3, 6
TOPIC_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,49}$")
BUZZWORDS = ("powerful", "seamless", "robust", "cutting-edge", "leverages",
             "comprehensive solution", "best-in-class", "next-generation")
SECTIONS = ("domain", "function", "technology")

# README drafts, for repos that have none. The draft lands as a PR in the target
# repo, which may be public, so these checks lean towards refusing.
README_MAX_LINES = 120
SECRET_SHAPES = {
    "sk": re.compile(r"\bsk-[A-Za-z0-9_-]{8,}"),
    "ghp": re.compile(r"\bghp_[A-Za-z0-9]{8,}"),
    "slack": re.compile(r"\bxox[bap]-[A-Za-z0-9-]{8,}"),
    "aws": re.compile(r"\bAKIA[0-9A-Z]{12,}"),
    "private_key": re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"),
}
# A macOS or Linux home directory, or a tilde path.
PERSONAL_PATH = re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+|~/")
HEADING = re.compile(r"^#{1,6}\s")
# Lines that are not a "what it does" sentence: fences, tables, lists, images,
# badges, HTML.
NOT_PROSE = re.compile(r"^(```|~~~|\||[-*+]\s|\d+\.\s|!\[|\[!\[|<)")


def name_pattern(name: str) -> re.Pattern:
    # Hyphen-aware: "secret-thing" must not match inside "secret-thing-public",
    # and a short private name must not hide inside a longer public one.
    return re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(name) + r"(?![A-Za-z0-9_-])",
                      re.IGNORECASE)


def readme_violations(text: str, private_names: list[str] | None,
                      check_private: bool) -> list[str]:
    """Deterministic checks on a README draft; empty means clean.

    private_names is None when the list could not be had; with check_private
    that fails closed rather than passing a public draft unchecked.
    """
    v: list[str] = []
    if not text.strip():
        return ["readme_empty"]
    lines = text.strip("\n").splitlines()
    if len(lines) > README_MAX_LINES:
        v.append(f"readme_too_long:{len(lines)}")
    first = next((i for i, ln in enumerate(lines) if ln.strip()), None)
    if first is None or not re.match(r"^#\s+\S", lines[first]):
        v.append("readme_no_h1")
    else:
        summary = False
        for ln in lines[first + 1:]:
            stripped = ln.strip()
            if HEADING.match(stripped):
                break
            if stripped and not NOT_PROSE.match(stripped):
                summary = True
                break
        if not summary:
            v.append("readme_no_summary")
    for kind, rx in SECRET_SHAPES.items():
        if rx.search(text):
            v.append(f"readme_secret:{kind}")
    if PERSONAL_PATH.search(text):
        v.append("readme_personal_path")
    if check_private:
        if private_names is None:
            v.append("readme_private_names_unchecked")
        else:
            for name in private_names:
                if name_pattern(name).search(text):
                    v.append(f"readme_private_name:{name}")
    return v


def fetch_private_names(owner: str) -> list[str] | None:
    """Every private repo name in owner, from gh. None when gh cannot say."""
    try:
        proc = subprocess.run(
            ["gh", "repo", "list", owner, "--visibility", "private",
             "--limit", "200", "--json", "name"],
            capture_output=True, text=True, timeout=60,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if proc.returncode != 0:
        return None
    try:
        return [r["name"] for r in json.loads(proc.stdout or "[]") if r.get("name")]
    except (json.JSONDecodeError, TypeError, KeyError):
        return None


class PrivateNames:
    """Private repo names per owner: repos.json when it lists any, else gh."""

    def __init__(self, repos: list[dict] | None):
        self.repos = repos or []
        self.cache: dict[str, list[str] | None] = {}

    def visibility(self, nwo: str) -> str | None:
        for row in self.repos:
            if row.get("nwo") == nwo:
                return row.get("visibility")
        return None

    def for_owner(self, owner: str) -> list[str] | None:
        if owner not in self.cache:
            rows = [r["nwo"].split("/", 1)[1] for r in self.repos
                    if r.get("nwo", "").split("/")[0] == owner
                    and str(r.get("visibility") or "").lower() == "private"]
            self.cache[owner] = rows if rows else fetch_private_names(owner)
        return self.cache[owner]


def load_taxonomy(path: Path) -> dict[str, list[str]]:
    """Parse the backticked term leading each bullet, per ## section."""
    tax: dict[str, list[str]] = {s: [] for s in SECTIONS}
    current: str | None = None
    for line in path.read_text().splitlines():
        heading = re.match(r"^##\s+(.+?)\s*$", line)
        if heading:
            name = heading.group(1).strip().lower()
            current = name if name in tax else None
            continue
        if current:
            bullet = re.match(r"^-\s+`([^`]+)`", line)
            if bullet:
                tax[current].append(bullet.group(1))
    return tax


def validate(proposal: dict, tax: dict[str, list[str]],
             names: PrivateNames | None = None) -> list[str]:
    """Return violation codes; empty means clean."""
    v: list[str] = []
    proposed = proposal.get("proposed") or {}
    desc = proposed.get("description")
    topics = proposed.get("topics") or []

    if desc is not None:
        stripped = desc.strip()
        if not stripped:
            v.append("description_empty")
        if len(stripped) > DESC_HARD:
            v.append("description_too_long")
        elif len(stripped) > DESC_TARGET:
            v.append("description_over_target")
        low = stripped.lower()
        for word in BUZZWORDS:
            if word in low:
                v.append(f"buzzword:{word}")
        name = proposal.get("nwo", "").split("/")[-1].lower()
        # The house style rule is "never OPEN with the repo name" (§ Description
        # house style), but this tested equality — so "repo-meta: proposes accurate
        # descriptions" passed while restating the name in the position the rule is
        # about. Compare on a normalized prefix, and require a word boundary after
        # it so "repo-metadata ..." is not flagged as restating "repo-meta".
        norm = low.replace("-", " ").strip()
        nname = name.replace("-", " ").strip()
        if nname and (norm == nname or
                      (norm.startswith(nname) and
                       (len(norm) == len(nname) or not norm[len(nname)].isalnum()))):
            v.append("restates_name")

    if not TOPIC_MIN <= len(topics) <= TOPIC_MAX:
        v.append(f"topic_count:{len(topics)}")
    for topic in topics:
        if not TOPIC_RE.match(topic):
            v.append(f"topic_format:{topic}")
    if topics:
        if not any(t in tax["domain"] for t in topics):
            v.append("no_domain_term")
        if not any(t in tax["function"] for t in topics):
            v.append("no_function_term")

    readme = proposed.get("readme")
    if readme is not None:
        # Only a MISSING README is ever drafted; an existing one is never
        # rewritten. Anything but an explicit has_readme=false is refused.
        if proposal.get("has_readme") is not False:
            v.append("readme_exists")
        if not isinstance(readme, str):
            v.append("readme_not_text")
        else:
            nwo = proposal.get("nwo", "")
            names = names or PrivateNames(None)
            vis = proposal.get("visibility") or names.visibility(nwo)
            # Unknown visibility is treated as public: fail closed.
            public = str(vis or "public").lower() != "private"
            private = names.for_owner(nwo.split("/")[0]) if public else []
            v += readme_violations(readme, private, public)
    return v


def engine_none(profile: dict, tax: dict[str, list[str]]) -> dict:
    """Deterministic topic matching. Never proposes a description."""
    haystack = " ".join([
        profile.get("readme_head") or "",
        profile.get("claude_md_head") or "",
        " ".join(profile.get("tree", [])),
        " ".join(profile.get("recent_commits", [])),
        profile.get("nwo", ""),
    ]).lower()
    hits: list[str] = []
    for section in SECTIONS:
        for term in tax[section]:
            if term in haystack and term not in hits:
                hits.append(term)
    langs = profile.get("languages") or {}
    if langs:
        top = max(langs, key=langs.get).lower()
        if top in tax["technology"] and top not in hits:
            hits.append(top)
    return {
        "description": None,
        "topics": (hits or profile.get("current", {}).get("topics", []))[:TOPIC_MAX],
    }


def engine_agent(profile: dict, tax: dict[str, list[str]]) -> dict:
    """Emit an empty proposal for the session agent to fill at the gate."""
    return {"description": None, "topics": [], "readme": None}


def finalize(proposal: dict, tax: dict[str, list[str]], engine: str,
             names: PrivateNames | None = None) -> dict:
    violations = validate(proposal, tax, names)
    proposal["violations"] = violations
    hard = [v for v in violations if not v.startswith("description_over_target")]
    # No special case for engine == "agent": an unfilled agent placeholder has no
    # topics, so topic_count already marks it needs_revision, and one the agent
    # has filled in must be able to pass on --validate-only.
    proposal["status"] = "needs_revision" if hard else "ok"
    return proposal


def main() -> int:
    ap = argparse.ArgumentParser(description="Propose and validate repo metadata.")
    ap.add_argument("--profiles")
    ap.add_argument("--taxonomy", required=True)
    ap.add_argument("--out")
    # Default: local when REPO_META_LOCAL_LLM names a local_llm.py, agent otherwise.
    ap.add_argument("--engine", choices=("local", "agent", "none"), default=None)
    ap.add_argument("--descriptions", choices=("improve", "fill-empty", "off"),
                    default="improve")
    ap.add_argument("--dump-taxonomy", action="store_true")
    ap.add_argument("--validate-only", action="store_true")
    ap.add_argument("--proposals", help="with --validate-only: file to re-check")
    ap.add_argument("--local-llm", default=None,
                    help="path to local_llm.py (default: $REPO_META_LOCAL_LLM)")
    ap.add_argument("--repos", default=None,
                    help="repos.json from discover.py: visibility and private names "
                         "for README checks (without it, gh is asked)")
    args = ap.parse_args()

    tax = load_taxonomy(Path(args.taxonomy))
    names = PrivateNames(json.loads(Path(args.repos).read_text()) if args.repos else None)

    if args.dump_taxonomy:
        print(json.dumps(tax, indent=2))
        return 0

    if args.validate_only:
        if not args.proposals or not args.out:
            raise SystemExit("--validate-only needs --proposals and --out")
        proposals = json.loads(Path(args.proposals).read_text())
        rechecked = [finalize(p, tax, p.get("engine", "none"), names) for p in proposals]
        Path(args.out).write_text(json.dumps(rechecked, indent=2) + "\n")
        bad = sum(1 for p in rechecked if p["status"] != "ok")
        print(f"validated {len(rechecked)} proposals, {bad} need revision")
        return 0

    if not args.profiles or not args.out:
        raise SystemExit("need --profiles and --out")

    sys.path.insert(0, str(Path(__file__).parent))
    from local_engine import EngineUnavailable, configured_local_llm, draft

    llm = args.local_llm or configured_local_llm()
    engine = args.engine or ("local" if llm else "agent")
    proposals = []
    for path in sorted(Path(args.profiles).glob("*.json")):
        if path.name == "_errors.json":
            continue
        profile = json.loads(path.read_text())
        if engine == "local":
            try:
                proposed = draft(profile, tax, llm)
            except EngineUnavailable as exc:
                print(f"local engine unavailable ({exc}); falling back to the "
                      f"agent engine for the rest of this run", file=sys.stderr)
                engine = "agent"
                proposed = engine_agent(profile, tax)
        elif engine == "agent":
            proposed = engine_agent(profile, tax)
        else:
            proposed = engine_none(profile, tax)

        if args.descriptions == "off":
            proposed["description"] = None
        elif (args.descriptions == "fill-empty"
              and profile.get("current", {}).get("description")):
            proposed["description"] = None

        slot = {"description": proposed.get("description"),
                "topics": proposed.get("topics") or []}
        # A README slot only where the profile says there is none. Only the agent
        # engine fills it; every other engine leaves it null, which proposes nothing.
        if profile.get("has_readme") is False:
            slot["readme"] = proposed.get("readme")
        proposals.append(finalize({
            "nwo": profile["nwo"],
            "visibility": names.visibility(profile["nwo"]) or profile.get("visibility"),
            "has_readme": profile.get("has_readme"),
            "current": profile.get("current", {"description": None, "topics": []}),
            "proposed": slot,
            "rationale": proposed.get("rationale", ""),
            "engine": engine,
            "status": "ok",
            "violations": [],
        }, tax, engine, names))

    Path(args.out).write_text(json.dumps(proposals, indent=2) + "\n")
    bad = sum(1 for p in proposals if p["status"] != "ok")
    print(f"proposed {len(proposals)} repos, {bad} need revision -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
