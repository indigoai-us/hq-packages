# hq-pack-awwwards

`/awwwards`: an agent skill that builds a complete, award-caliber website from a one-line
prompt ("make me a portfolio, my name is Ana"). It covers concept, art direction, typography,
motion, WebGL, page transitions, real content, SEO, accessibility and performance, then runs a
visual QA loop in a real browser. Next.js by default, Astro for animation-heavy static
showcases, or the stack the project already uses.

## Credit

Created by **Julio ([juliobsz](https://github.com/juliobsz))**. Source:
<https://github.com/juliobsz/skills>. Licensed MIT; the upstream `LICENSE` with Julio's
copyright notice is included unchanged in this pack.

Ported from upstream commit `5bdb14f72d14bcaebe461f95fe6640210857384c`. The skill directory
(`skills/awwwards/`: `SKILL.md`, `references/`, `scripts/`) is copied verbatim, with one
deviation listed below. Upstream test harnesses, CI config and the Claude Code plugin manifest
are not included.

## Deviations from upstream

- `skills/awwwards/scripts/shoot.mjs`: the axe-core CDN fallback URL is pinned to an exact
  version, `axe-core@4.14.0`, instead of upstream's floating `axe-core@4`, so the script
  always injects a known build into the page under test.

## Cover image

`cover.jpg` at the pack root is the HQ marketplace card image (1600x900, original HQ artwork
made for this pack). It is not part of the upstream project and is not covered by the
upstream license.

## Contents

| Path | What |
|------|------|
| `skills/awwwards/SKILL.md` | The skill: phases, quality bar, final-message format |
| `skills/awwwards/references/` | 15 reference files (art direction, motion, engine, WebGL, Next.js, Astro, QA rubric, …) |
| `skills/awwwards/scripts/` | Node helper scripts the skill runs in the user's project |

## Requirements and runtime behavior

- Node 20+ (upstream README recommends 22.20+). Playwright and axe-core in the target project
  for the screenshot and accessibility passes.
- No hooks. Nothing runs on install. The scripts run only when the agent invokes them while
  building a site:
  - `font.mjs` downloads web fonts from Google Fonts or Fontshare into the project.
  - `photos.mjs` downloads placeholder photos from picsum.photos.
  - `shoot.mjs` drives a local Chromium against a local server; if axe-core is not installed
    in the project it fetches `axe-core@4.14.0` from cdn.jsdelivr.net and injects it into the page.
  - `serve.mjs` / `audit.mjs` serve and audit the built site on 127.0.0.1.
- The skill may tell the agent to run `npx playwright install chromium`, and may suggest
  (not run) installing the optional third-party `anatomy` skill via `npx skills add`.

## Install

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-awwwards
```
