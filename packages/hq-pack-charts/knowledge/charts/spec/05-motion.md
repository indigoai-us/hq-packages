# 05 — Motion

Motion is CSS only. A chart draws completely with no script; the animation is a
reveal, not a dependency.

## Verbs

| Class | Motion | Use on |
|---|---|---|
| `ch-grow` | scale from the left | horizontal bars, share bars |
| `ch-rise` | scale from the bottom | columns, histograms |
| `ch-pop` | scale from centre with a small overshoot | dots, unit squares, status cells |
| `ch-draw` | stroke draws along its length | lines, slopes, ring arcs |
| `ch-fade` | opacity | labels, notes, anything that should not move |

## Stagger

Add `ch-d1` … `ch-d12` to step the delay by `--ch-stagger` (28 ms). A ranked bar
chart with ten bars staggers `ch-d1` to `ch-d10`; a unit grid of 200 squares
staggers by row, not by square. Nothing waits longer than about 1.3 s to appear.

## Rules

- Labels and values `ch-fade` in after their marks, never before.
- The hero appears last, or draws slowest. It is the thing the eye should land on.
- No motion on structure: gridlines, axes, and rules are static.
- `prefers-reduced-motion` and print both disable every verb. The stylesheet does
  this; do not add your own keyframes.
- No looping, no hover-triggered motion, no JavaScript replay.

## Rings and `ch-draw`

`ch-draw` sets `stroke-dasharray`/`stroke-dashoffset` in CSS, which overrides the
same presentation attributes on the element. A `<circle>` carrying a dasharray
attribute to show a share will therefore draw to 100% and misstate it. Draw a
partial ring as a `<path>` arc whose sweep is exactly share × 360, and put
`ch-draw` on that path. The track stays a full `<circle class="ch-ring ch-ring--track">`.
