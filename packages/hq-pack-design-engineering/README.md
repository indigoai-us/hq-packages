# hq-pack-design-engineering

**Skills for Design Engineers — by [Emil Kowalski](https://emilkowal.ski/).**

Fifteen skills that give an agent *taste* when it builds or reviews interfaces:
right easing and `transform-origin`, sub-300ms motion, building animations from
scratch on the web and in React Native/Expo, keeping animations inside the frame
budget, making web apps feel native on a phone, modern Swift, the vocabulary to
name a motion effect, Apple's interaction principles translated for the web,
worst-case data stress tests, a Sonner toast guide, a curated UI-library picker,
a divergent prototyping harness, and strict animation review/audit workflows.

Ported verbatim into the HQ marketplace from Emil's open-source repo — every
skill is unmodified and the original MIT license is preserved (see
[`LICENSE`](./LICENSE)).

## Install

```bash
hq install marketplace:design-engineering
```

## Skills

| Skill | What it does |
| --- | --- |
| **emil-design-eng** | The main skill — Emil's philosophy on UI polish, component design, and animation decisions. |
| **review-animations** | Reviews animation/motion code against a strict craft bar. Approval is earned. |
| **improve-animations** | Audits a codebase's motion and produces prioritized, self-contained fix plans other agents can execute. |
| **find-animation-opportunities** | Finds places in a UI that should animate — and rejects everything that shouldn't. Read-only. |
| **animation-vocabulary** | Reverse glossary: turns "the bouncy thing when a popover opens" into the exact term. |
| **apple-design** | Apple's principles for interface design and fluid, physical motion, translated for the web. |
| **pick-ui-library** | Picks the right library for a frontend task from a curated, opinionated list. |
| **prototype** | Builds several genuinely different versions of a UI piece behind a visual picker so you can flip through them live. |
| **animate** | Builds an animation from scratch, deciding in order: should it animate, why, which tool, which properties, which curve and duration. |
| **animate-expo** | The same decision order for React Native and Expo: which thread it runs on, which properties, springs, gestures. |
| **animation-performance** | Keeps web animations inside the frame budget and finds the cause when one drops frames. |
| **mobile-native** | Small CSS and meta-tag fixes that make a web app feel installed on a phone: sticky hover, tap highlight, safe areas, overscroll. |
| **write-swift** | How to write modern Swift: value types, Swift 6 concurrency, protocols, SwiftUI state. |
| **break-ui** | Tries to break a piece of UI with worst-case data: long names, missing fields, huge counts, non-Latin text. |
| **ask-sonner** | Guide to Sonner, the React toast library. |

The repo root also carries Emil's `performance-cheatsheet.md`.

## Attribution & license

All skill content is © 2026 Emil Kowalski, released under the MIT License and
reproduced here unmodified. Source: <https://github.com/emilkowalski/skills>
(commit `2d22863`). This pack repackages that content for installation through
HQ; it adds no new skill content of its own.

- Emil's site: <https://emilkowal.ski/>
- Emil's course: <https://animations.dev/>
- Newsletter: <https://animations.dev/skills>

See [`LICENSE`](./LICENSE) for the full MIT text.
