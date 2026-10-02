# .github

Org-wide files for [public-media-work](https://github.com/public-media-work), work for public media institutions by @mriechers.

## How this repo works

`profile/README.md` is the org's landing page on GitHub. It has two generated regions between HTML comment markers, and everything outside them is written by hand:

- **Public projects** (`BEGIN:public-repos` / `END:public-repos`): a table of the org's non-fork, non-archived public repos, rendered from their GitHub descriptions. Edit a repo's description on GitHub, not the table.
- **Private work** (`BEGIN:capabilities` / `END:capabilities`): prose describing what the private tools do, grouped by capability area.

A `last-refreshed` comment at the bottom records the last full refresh.

## Skills

- **`refresh-org-profile`** (`.claude/skills/refresh-org-profile/`): the single entry point. It sweeps repo descriptions, re-renders the public table, redrafts the capabilities prose, runs the leak check, and opens a PR.
- **`repo-meta`** (`.claude/skills/repo-meta/`): proposes codebase-grounded descriptions and topics for the org's repos and writes them back only after a human approves. In progress on its own PR.

Both are to be bundled together after they pass skill-ops graduation.

## No private names

This repo is public. No private repo name may appear anywhere in it: the README, skills, scripts, tests, commit messages, or PR bodies. Private work is described by what it does, never by name, quote, or identifying data source. Before every commit, run:

```bash
python3 .claude/skills/refresh-org-profile/scripts/org_profile.py check-leaks
```

It checks the live private repo list against the README and every tracked or staged file. Tests use synthetic names only.

## Updates are manual

There are no scheduled jobs. Every update is a manual `refresh-org-profile` run that ends in a PR, and a person merges it. The workflows under `.github/workflows/` are fleet-managed; don't edit them here.

## Tests

```bash
bash tests/org-profile.test.sh
```
