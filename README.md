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
| [`hq-pack-gbrain`](./packages/hq-pack-gbrain) | Optional per-company GBrain runtime for brain-first lookup, capture, search, and memory gardening |

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
