# 08 — Authoring a type

When nothing in the registry can carry a shape, add a type rather than improvising
in a deliverable. The bar: someone who has read the spec files and only your new
card could redraw it with fresh data without inventing a single number.

## Before drawing: the encoding statement

Write one line per visual channel:

```
position-x:  period (evenly spaced, Jan–Dec)
position-y:  value (linear, zero-based)
length:      —
area:        —
lightness:   rank within period (ramp-1 … ramp-5)
```

If a channel cannot be filled in, the data is not understood yet. Go and get the
structure before drawing. Copying a figure's look without its encoding is how
the pictorial-bar class of error happens.

For a reference image someone hands you, name the school first (editorial density,
marginalia, hand-set feel) and keep it; it is part of the encoding, not decoration.

## Then

1. Find the nearest registry type and inherit its skeleton: card structure,
   padding, label placement, motion verbs, and reading rhythm.
2. Compose with existing classes only. If a new role is genuinely needed, add it to
   `chart.css` with a comment, re-run `sync-assets.py`, and mention it in the
   CHANGELOG.
3. Add a card to the right gallery file with a deterministic dataset, a real
   conclusion title, a subtitle with unit and range, and a source line.
4. Add the registry entry with an honest `tier` and `status: spec`, and the
   selection-table row in `types/README.md`.
5. Run `scripts/test-lint.py` and `scripts/lint-chart.py --all`.
6. View it on the contact sheet beside its family.

## Do not

- Ship a `status: planned` type as if it existed.
- Add a chart library, a script, or an external image to make a type possible.
- Add a fourth palette or a seventh series slot for one type.
