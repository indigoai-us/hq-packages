# 01 — Tokens

## The contract

> **The SVG carries semantic classes. It never carries a colour.**

Every paint decision lives in `assets/chart.css`. Re-skinning a chart means replacing
the `:root` block or flipping `data-ch-palette`; nothing in the figure changes.
`scripts/lint-chart.py` fails any file with a colour literal in an SVG attribute
(`CH101`), a `font-family` attribute (`CH102`), or a `style=` attribute (`CH103`).

This pack shares its role vocabulary with `hq-pack-diagrams`. Every `--ch-*`
surface, ink, structure, delta, and font token falls back to its `--dg-*` twin, so
a page that already carries a diagram skin, or a company brand pack mapped through
the design-styles binding formula, re-skins its charts for free.

## Roles

Refer to roles by class name. Never look up a hex and inline it.

### Surface and structure

| Class | Role |
|---|---|
| `ch-bg` | Card ground, opt-in (leave it out for transparent export) |
| `ch-band` | Recessed band: a highlighted period, a target zone |
| `ch-grid` | Hairline gridlines |
| `ch-axis` | Axis baseline |
| `ch-tick` | Tick marks |
| `ch-rule` | Any other hairline: leader lines, dividers |
| `ch-target` | Dashed reference line: goal, average, last year |
| `ch-mask` | Paper-coloured halo behind a label that crosses a mark |

### Text

| Class | Role |
|---|---|
| `ch-t-big` | The headline number in a signal card |
| `ch-t-value` | A value printed at the end of a bar or on a point |
| `ch-t-label` | Category and entity names |
| `ch-t-axis` | Axis values, tabular figures |
| `ch-t-note` | Footnotes, marginalia inside the figure |
| `ch-t-mono` | Add for codes, ids, dates |
| `ch-t-muted` `ch-t-soft` `ch-t-hero` `ch-t-inv` `ch-t-up` `ch-t-down` | Colour modifiers |
| `ch-t-end` `ch-t-mid` | Anchor modifiers |

### Data marks

| Class | Role |
|---|---|
| `ch-mark` | The default mark: series 1 |
| `ch-hero` | The one thing the reader should see first |
| `ch-quiet` | Everything that is not the hero, when a hero exists |
| `ch-track` | The empty part of a bar, ring, or bullet range |
| `ch-s1` … `ch-s6` | Series slots, for multi-series figures only |
| `ch-r1` … `ch-r5` | Sequential ramp, light to dark, for ordered values |
| `ch-up` `ch-down` `ch-flat` and `-tint` | Semantic deltas, always paired with a sign or label |
| `ch-fill` | Add to a series class for an area or band at fill opacity |
| `ch-line` `ch-line--hero` `ch-line--quiet` `ch-line--s2…s6` `ch-line--up/down` | Strokes for line charts |
| `ch-stroke` `ch-stroke--hair` `ch-stroke--soft` `ch-stroke--hero` | Outline strokes |
| `ch-ring` `ch-ring--track` `ch-ring--hero` | Ring segments |
| `ch-dot` `ch-dot--open` `ch-dot--hero` `ch-dot--quiet` | Point marks |

### The hero rule

At most **one hero per card**. A hero mark, a hero line, or a hero text: choose
one. If two things are equally important, the chart has two conclusions and should
be two charts. When a hero exists, everything else is `ch-quiet` or a series slot,
never a second hero.

### Series slots

Series 1 is the same hue as the hero, so a focal series and a focal label agree.
Six slots exist; a legible chart uses three. Past four unordered categories, group
the tail into "other" or switch to a ranked or small-multiples type.

Do not reach for series slots to add colour to a single-series chart. That is what
palettes are for (`04-colour.md`).

## Type scale

| Token | Size | Use |
|---|---|---|
| `--ch-fs-big` | 44px | One headline number |
| `--ch-fs-value` | 22px | End-of-bar values, ring centres |
| `--ch-fs-title` | 16px | Card conclusion (HTML, not SVG) |
| `--ch-fs-sub` | 11.5px | Card subtitle (HTML) |
| `--ch-fs-label` | 10px | Names inside the figure |
| `--ch-fs-axis` | 9.5px | Axis values |
| `--ch-fs-note` | 9px | Marginalia, source |

**Floors.** Inside the SVG, nothing renders below 7px in a half-width card or 6px in
a wide card (`CH150`). When labels do not fit, the answer is a `<title>` hover, a
footnote, fewer labels, or a wider card. It is never smaller type.

## Stroke scale

`--ch-sw-hair` 0.6 · `--ch-sw-thin` 1 · `--ch-sw-line` 1.6 · `--ch-sw-bold` 2.4.
Hairlines for structure, thin for outlines, line for data lines, bold for the hero
line only.

## Geometry

Coordinates are integers or halves. Card viewBoxes: half-width `0 0 520 300`
(or taller), wide `0 0 1080 320` (or taller). Keep 8px of padding inside the
viewBox on every side and reserve the right 60–80px of a wide chart for end labels.

Bar corner radius is 0 or 2. Rings are 10px strokes. Dots are r 2.5–5, scaled by
`sqrt` when they encode a value (`02-honesty.md`).
