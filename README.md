# hq-packages

Content packs for [HQ by Indigo](https://github.com/indigoai-us/hq-core) — the personal operating system for AI workers.

`hq-core` ships a minimal scaffold. The rich, opt-in capabilities live here as separate `@indigoai-us/hq-pack-*` packages and install into `packages/` via `hq install`.

## Packs

| Pack | What it adds |
|------|--------------|
| [`hq-pack-design-styles`](./packages/hq-pack-design-styles) | Curated style packs (brutalist, editorial, warm-neutral, etc.) — registry + pack schema + reference MDCs |
| [`hq-pack-design-quality`](./packages/hq-pack-design-quality) | Typography, color, spatial, and motion quality references for design-audit skills |
| [`hq-pack-gemini`](./packages/hq-pack-gemini) | Six Gemini CLI workers (coder, reviewer, frontend, designer, stylist, ux-auditor) + `gemini-cli` knowledge. Conditional — skipped when `gemini` is not on `PATH` |
| [`hq-pack-gstack`](./packages/hq-pack-gstack) | gstack-team workers (26 g-* skills) + `scripts/gstack-bridge.sh` |
| [`hq-pack-slack-bot`](./packages/hq-pack-slack-bot) | Per-bot Slack mention watcher + spawned-worker template. Pairs with hq-pro `/hq-new-bot`. |
| [`hq-pack-hq-slack`](./packages/hq-pack-hq-slack) | MCP-free Slack messaging CLI (post/read/reply/DM/search/upload) acting AS you via your own Slack app's user token — plus a guided full-access app setup. |
| [`hq-pack-work-mesh`](./packages/hq-pack-work-mesh) | Live work mesh: listen cache, genesis on `/prd`, Board/Status helpers, isolated agent-box install. Git-only (`private` on npm until hq-core promotion). |

## Retired packs

| Pack | Status |
|------|--------|
| `hq-pack-engineering` | **Absorbed into `hq-core`.** Its 24 skills (`/tdd`, `/review`, `/ship`, `/land`, `/run-project`, `/prd`, `/architect`, …), 6 workers, 4 knowledge sets, 3 policies, and 3 hooks now ship with the base release, so nothing needs installing. Extracted from core in hq-core v15.0.0 and merged back in 2026-08. Last pack version was 1.8.0; the source remains in this repo's history. Installed copies are inert once core ships the same content — remove one with `hq packs uninstall hq-pack-engineering`. |

## Install a pack

```bash
hq install @indigoai-us/hq-pack-gemini                                       # npm (when published)
hq install github:indigoai-us/hq-packages#packages/hq-pack-gemini            # git (no npm auth required)
hq install ./packages/hq-pack-gemini                                         # local path
```

`hq-core`'s `core.yaml` lists the recommended packs that a fresh `npx create-hq` run prompts to install. `--full` installs everything unconditionally; `--minimal` skips the prompt.

## Pack layout

Each pack declares `package.yaml` at its root:

```yaml
name: hq-pack-{slug}
version: 1.0.0
publisher: '@indigoai-us'
access: public
requires:
  hqCore: '>=12.0.0'
contributes:
  workers: [worker-a, worker-b]
  knowledge: [shared-knowledge-slug]
  skills: [skill-name]
  hooks: []     # run on tool events — user-confirm prompt on install
  policies: []
  commands: []
```

Schema: `knowledge/public/hq-core/package-yaml-spec.md` in `hq-core` (authoritative).

## License

MIT.
