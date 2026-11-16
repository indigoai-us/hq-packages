# Boring Marketing Skills in HQ

This folder ships with `hq-pack-boring-marketing`, a port of
[boringmarketer/boring-marketing-skills](https://github.com/boringmarketer/boring-marketing-skills)
v4.1.1 at commit `7c6678c857fe514f79396ea607aa2a56ea82e676`. The skills are by James
Dickerson (Boring Marketing, LLC) and are MIT licensed. The license text is in the pack's
`LICENSE` file and must stay with every copy.

## What the port changed

Each of the 32 `SKILL.md` files gets one short "Running in HQ" note right after its
frontmatter. Everything else in each skill folder (the skill text, `references/`,
`modes/` and `scripts/`) is upstream and unchanged. Skill names are unchanged, so the
upstream cross-references (`/start-here`, `/paid-ads`, `${CLAUDE_SKILL_DIR}/../start-here/...`)
still resolve when the pack is installed.

## Where the files go

Upstream skills treat the current folder as a marketing workspace: `./MARKETING.md`,
`./brand/`, `./brands/<client>/` and `./campaigns/`. In HQ that workspace is the active
company's marketing folder:

```
companies/{co}/knowledge/marketing/
  MARKETING.md
  brand/          brand.yaml, voice-profile.md, positioning.md, voc.md, learnings.md, ...
  campaigns/      drafts, ad matrices, content plans
  brands/<slug>/  only for prospects that have no HQ company yet
```

Run the helper scripts from that folder, or pass `--root companies/{co}/knowledge/marketing`
to the scripts that take it (`brand_context.py`). If the company already has brand
material (for example `knowledge/brand-voice/`), `/start-here` and `/brand-voice` read it
first and do not overwrite it.

## Clients and company isolation

Upstream "agency mode" keeps one folder per client under `./brands/` and ships a hook that
blocks writes to the wrong client's folder. HQ already isolates companies, so:

- A client with its own HQ company works out of that company's marketing folder, in a
  session bound to that company.
- `./brands/<slug>/` inside one company's folder is for prospects only
  (`/find-local-clients`, `/pitch-the-fix`, prospect audits).
- Never copy one company's brand files, learnings or keys into another company.

## Keys

`TOOLS.md` lists the optional keys (Firecrawl, Exa, DataForSEO, Google Places, PageSpeed,
Meta, Google Ads, Replicate and others). Store them with HQ secrets and inject them with
`hq secrets exec` or `hq run`. Every skill has a free path that needs no key.

## Outbound actions

Upstream already forbids auto-publishing, auto-sending and spending without a person.
In HQ the same rule applies through the charter: emails, social posts, review replies,
and ad launches wait for the user's OK on the exact content. `meta-ads` creates
everything PAUSED and its script dry-runs unless `--apply` is passed.

## Parts of upstream that were left out

- `automations/hooks/hooks.json`: the client-folder guard and the asset-log append hook.
  HQ company isolation covers the guard. Skills that save an asset should append the line
  to `brand/assets.md` themselves.
- Repo tooling under `_system/scripts/` (installer, packager, doctor, banned-word check,
  freshness check, version restamp). The three runtime scripts every skill calls
  (`brand_context.py`, `capability.py`, `route.py`) ship in `skills/start-here/scripts/`.
- The upstream Python test suite and fixtures.
- The Claude Code plugin manifests and the upstream CI workflow.

## Where the rest of upstream lives in this pack

| Upstream path | In this pack |
|---|---|
| `README.md`, `SYSTEM-GUIDE.md`, `TOOLS.md`, `CHANGELOG.md` | `knowledge/boring-marketing/` |
| `_system/CONVENTIONS.md`, `_system/VERSION` | `knowledge/boring-marketing/CONVENTIONS.md`, `VERSION` |
| `agents/research.md` | `knowledge/boring-marketing/agents/research.md` |
| `automations/routines/`, `automations/workflows/` | `knowledge/boring-marketing/automations/` |

When a skill asks for "research agents" (`/start-here` deep foundation,
`/competitive-intel`), spawn subagents and give each the brief in `agents/research.md`
plus the task. When a skill points to a routine in `automations/routines/`, schedule it
with `/schedule` (or the HQ schedule tooling) using that file as the prompt.
