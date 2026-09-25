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
import sys
from pathlib import Path

DESC_TARGET = 120
DESC_HARD = 350
TOPIC_MIN, TOPIC_MAX = 3, 6
TOPIC_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,49}$")
BUZZWORDS = ("powerful", "seamless", "robust", "cutting-edge", "leverages",
             "comprehensive solution", "best-in-class", "next-generation")
SECTIONS = ("domain", "function", "technology")


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


def validate(proposal: dict, tax: dict[str, list[str]]) -> list[str]:
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
    return v


def engine_none(profile: dict, tax: dict[str, list[str]]) -> dict:
    """Deterministic topic matching. Never proposes a description."""
    haystack = " ".join([
        profile.get("readme_head", ""),
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
    return {"description": None, "topics": []}


def build(profile: dict, tax: dict[str, list[str]], engine: str,
          descriptions: str) -> dict:
    if engine == "none":
        proposed = engine_none(profile, tax)
    elif engine == "agent":
        proposed = engine_agent(profile, tax)
    elif engine == "local":
        from local_engine import draft  # Task 5
        proposed = draft(profile, tax)
    else:
        raise SystemExit(f"unknown engine: {engine}")

    if descriptions == "off":
        proposed["description"] = None
    elif descriptions == "fill-empty" and profile.get("current", {}).get("description"):
        proposed["description"] = None

    proposal = {
        "nwo": profile["nwo"],
        "current": profile.get("current", {"description": None, "topics": []}),
        "proposed": proposed,
        "rationale": proposed.pop("rationale", ""),
        "engine": engine,
        "status": "ok",
        "violations": [],
    }
    return finalize(proposal, tax, engine)


def finalize(proposal: dict, tax: dict[str, list[str]], engine: str) -> dict:
    violations = validate(proposal, tax)
    proposal["violations"] = violations
    hard = [v for v in violations if not v.startswith("description_over_target")]
    proposal["status"] = "needs_revision" if (hard or engine == "agent") else "ok"
    return proposal


def main() -> int:
    ap = argparse.ArgumentParser(description="Propose and validate repo metadata.")
    ap.add_argument("--profiles")
    ap.add_argument("--taxonomy", required=True)
    ap.add_argument("--out")
    ap.add_argument("--engine", choices=("local", "agent", "none"), default="local")
    ap.add_argument("--descriptions", choices=("improve", "fill-empty", "off"),
                    default="improve")
    ap.add_argument("--dump-taxonomy", action="store_true")
    ap.add_argument("--validate-only", action="store_true")
    ap.add_argument("--proposals", help="with --validate-only: file to re-check")
    args = ap.parse_args()

    tax = load_taxonomy(Path(args.taxonomy))

    if args.dump_taxonomy:
        print(json.dumps(tax, indent=2))
        return 0

    if args.validate_only:
        if not args.proposals or not args.out:
            raise SystemExit("--validate-only needs --proposals and --out")
        proposals = json.loads(Path(args.proposals).read_text())
        rechecked = [finalize(p, tax, p.get("engine", "none")) for p in proposals]
        Path(args.out).write_text(json.dumps(rechecked, indent=2) + "\n")
        bad = sum(1 for p in rechecked if p["status"] != "ok")
        print(f"validated {len(rechecked)} proposals, {bad} need revision")
        return 0

    if not args.profiles or not args.out:
        raise SystemExit("need --profiles and --out")

    proposals = []
    for path in sorted(Path(args.profiles).glob("*.json")):
        if path.name == "_errors.json":
            continue
        proposals.append(build(json.loads(path.read_text()), tax,
                               args.engine, args.descriptions))

    Path(args.out).write_text(json.dumps(proposals, indent=2) + "\n")
    bad = sum(1 for p in proposals if p["status"] != "ok")
    print(f"proposed {len(proposals)} repos, {bad} need revision -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
