# @indigoai-us/hq-pack-design-quality

HQ content pack: typography, color, spatial, motion quality references used by design-audit skills.

## Install

```bash
hq install @indigoai-us/hq-pack-design-quality
```

This drops `knowledge/design-quality/` into your HQ instance and wires it into `knowledge/public/design-quality/` via `hq core scan-packages`.

## Contents

- `knowledge/design-quality/` — typography, color, spatial, motion reference MDCs (consumed by design-audit and ux-auditor skills)

## Consumers

- `workers/public/dev-team/frontend-dev/` (audit / polish / typeset / harden skills)
- `workers/public/accessibility-auditor/`

## Requires

- `hq-core >= 15.0.179` (requires hq-cli >= 5.269.0; `hq core
  scan-packages` first shipped in hq-cli 5.89.0)
