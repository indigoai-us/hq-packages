# hq-pack-anatomy

The Anatomy skill for HQ. It builds crafted, interactive isometric SVG figures
that explain a technical idea as a real physical object, with optional WebGL
shaders and a 3D mode.

## Attribution

- Author: Ryan ([@wheresryan22](https://github.com/wheresryan22))
- Original repository: https://github.com/wheresryan22/anatomy
- License: MIT, copyright (c) 2026 Ryan. The upstream license is reproduced in
  [`LICENSE`](./LICENSE) and in [`skills/anatomy/LICENSE`](./skills/anatomy/LICENSE).
- Ported from commit `689dcf966e63d92be10a5d593c6e19e10acd4422` on `main`.

This pack is a repackaging of Ryan's work for HQ. All design, code, references
and examples are his. For documentation, the gallery, issues and contributions,
use the original repository.

## Contents

`skills/anatomy/` is the upstream skill, copied unchanged from the commit above:

| Path | What it is |
|---|---|
| `SKILL.md` | The skill instructions |
| `kit/` | The drawing kit (isometric projection, painter's order, lathe, tube, audit, WebGL helpers) |
| `references/` | Craft, motion, verify, kit, React, WebGL, 3D and walkthrough references |
| `scripts/` | Capture, drive and check scripts, plus the upstream regression tests |
| `examples/` | The eight upstream example figures and their built pages |
| `tests/fixtures/` | Fixtures used by the regression tests |
| `evals/` | Upstream skill evals |
| `agents/` | Upstream Codex interface metadata |

`cover.jpg` at the pack root is the HQ marketplace card image (lighthouse lens
room, from the HQ "Quiet Machines" wallpaper release). It is HQ artwork, not
part of the upstream project, and is not covered by the upstream license.

Not copied: the upstream README, changelog, contributing, code of conduct,
security policy and `.github/` folder.

## Requirements

Node.js 20.10 or later. Chrome or Chromium for the capture and check scripts
(set `CHROME_PATH` if it is not found). No npm dependencies.

## Use

```text
/anatomy explain how a token bucket rate limiter works, interactive
```

## Updating

Re-copy `SKILL.md`, `LICENSE`, `kit/`, `references/`, `scripts/`, `examples/`,
`tests/`, `evals/` and `agents/` from a newer upstream commit, then update
`upstream.ported_commit`, `upstream.ported_at` and `version` in `package.yaml`.
