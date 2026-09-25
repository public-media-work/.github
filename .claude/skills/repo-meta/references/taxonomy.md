# Topic taxonomy

Curated vocabulary, ported from the "Taxonomy Reference" phase of skill-ops
triage/commands/the-lodge/tag-repos.md when repo-meta superseded it. One
initiative-specific domain term was generalized to `wpm`; everything else is
unchanged. Prefer an existing term over inventing one.

## Domain

- `media-production` — content production workflows
- `public-media` — public media industry (general)
- `pbs-wisconsin` — PBS Wisconsin projects
- `wpm` — Wisconsin Public Media
- `wonder-cabinet` — Wonder Cabinet Productions
- `podcasting` — podcast production/tooling
- `journalism` — journalism tools
- `personal` — personal projects
- `homelab` — home infrastructure/hardware

## Function

- `automation` — automated workflows, pipelines
- `agent` — AI agent systems
- `agentic-ai` — AI agent infrastructure
- `mcp-server` — Model Context Protocol servers
- `obsidian-plugin` — Obsidian plugins
- `analytics` — data analysis, reporting
- `knowledge-management` — knowledge bases, PKM
- `second-brain` — second-brain ecosystem repos

## Technology

Use only when the tech is central, not incidental.

- `python`
- `typescript`
- `fastapi`
- `airtable`
- `home-assistant`
- `obsidian`
- `ghost-cms`
- `meshtastic`
- `mesh-networking`

## Rules

- 3–6 topics per repo — enough to be findable, not so many they are meaningless.
- At least one Domain term per repo.
- At least one Function term per repo.
- Technology terms only when the repo is primarily about that technology, or it is the main language.
- If a repo belongs to an organization's ecosystem, include that ecosystem's Domain term.
- New terms are acceptable when nothing fits — they are reported separately at the approval gate so the vocabulary grows deliberately.

## Description house style

- Say what the thing **does**, not what it is made of. "Folds laundry" beats "a Python utility".
- 120 characters or fewer. GitHub's hard cap is 350; anything near it is a paragraph, not a description.
- No trailing period.
- Never open with the repo name — GitHub already shows it.
- Banned as empty filler: powerful, seamless, robust, cutting-edge, leverages, comprehensive solution, best-in-class, next-generation.
