# MagicPath Agent Skills — integration setup (HQ)

> **Integration pack — links + setup only.** MagicPath's `agent-skills` repo ships
> **no LICENSE** (all-rights-reserved), so HQ does **not** redistribute any of its
> code. This pack contains zero copied upstream files. It is original
> HQ-authored setup + usage knowledge that points you at the vendor's own source,
> and credits the vendor. To use MagicPath's skills, install them from MagicPath
> directly using the steps below.

## What MagicPath Agent Skills is

MagicPath (vendor: **MagicPath AI**) publishes a set of agent skills for the open
cross-editor "Agent Skills" ecosystem (the `.claude-plugin` / `.codex-plugin` /
`.cursor-plugin` standard). The repo exposes a `magicpath` skill that brings
MagicPath's design-to-code workflow into Claude Code, Codex, and Cursor.

- **Vendor:** MagicPath AI
- **Source repo:** https://github.com/MagicPathAI/agent-skills
- **Tracked commit (at integration time):** `5e08ac90a5050a52abe4c28cbb700e989c111767`

## Install from the vendor (recommended path)

MagicPath packages its skills for Vercel's `skills` CLI. Install directly from the
vendor's repository so you get their canonical, up-to-date version:

```bash
# Install MagicPath's agent skills from their own repo (vendor source).
npx skills add MagicPathAI/agent-skills
```

This pulls the `magicpath` skill from MagicPath's repository into your editor's
skills directory. Because HQ holds no redistribution right here, HQ does not vendor
a copy — you install from MagicPath, and the skill stays current with their source.

## Using it inside HQ

Once installed via the vendor CLI above, the `magicpath` skill surfaces in your
editor like any other agent skill. Refer to MagicPath's own README and docs in the
source repo for the skill's commands and usage:

- Repo + README: https://github.com/MagicPathAI/agent-skills

## Why this is an integration pack, not a port

The HQ pack-porter license gate classified `MagicPathAI/agent-skills` as **REJECT**
(no LICENSE file → all-rights-reserved). Absence of a license is the strongest
restriction, not an implied grant — so the porter must not copy the upstream code
into a redistributable HQ pack. Instead it ships this **integration** pack: setup
instructions, usage pointers, and vendor links, with **no copied upstream code**.
A license/partnership reach-out to MagicPath has been logged (held, not sent); if
MagicPath adds a permissive license or grants permission, this can be upgraded to a
full port.

## Credit

All credit for these skills belongs to **MagicPath AI**
(https://github.com/MagicPathAI/agent-skills). This pack exists only to make their
work easy to find and install from HQ.
