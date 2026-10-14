# @indigoai-us/hq-pack-design-styles

HQ content pack: curated style packs (registry + pack schema + reference MDCs) for HQ design workers.

## Install

```bash
hq install @indigoai-us/hq-pack-design-styles
```

This drops `knowledge/design-styles/` into your HQ instance's `packages/hq-pack-design-styles/` directory and symlinks it into `knowledge/public/design-styles/` via `hq core scan-packages` on the next session start.

## Contents

- `knowledge/design-styles/` — registry.yaml + pack schema + per-pack MDCs (brutalist, editorial, warm-neutral, etc.)

## Consumers

- `workers/public/frontend-designer/` (required)
- `workers/public/paper-designer/` (required)
- `workers/public/dev-team/frontend-dev/` (context loader)

## Requires

- `hq-core >= 15.0.179` (requires hq-cli >= 5.269.0; the
  `hq core scan-packages` command is available from hq-cli 5.89.0)
