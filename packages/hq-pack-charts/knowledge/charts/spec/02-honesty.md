# 02 — Honesty

A chart is a claim about numbers. These rules keep the picture from saying more, or
less, than the numbers do. They are not style preferences; a violation is a defect.

## Proportion

- **Length encodes value linearly.** A bar twice as long is twice the value. Bars
  and columns start at zero, always.
- **No broken axes.** If one value dwarfs the rest, do one of: print the outlier's
  value and cap its bar with an explicit "off scale" marker; split into two charts
  (with and without the outlier); or switch to a type that handles range honestly
  (dot strip, ranked with log-free small multiples).
- **Area encodes value through `sqrt`.** A dot or square whose size means something
  uses `r = k · sqrt(v)`, never `r = k · v`. The linter cannot check this, so the
  self-check asks.
- **Angles encode share.** A ring segment's sweep is exactly `v / total · 360`.
  Never round a segment up to look fuller.
- **The linter checks bars.** Give each bar a `<title>` ending in `· value`; `CH181`
  warns when bars in one group are not proportional to those values.

## Units

- Every card subtitle names the unit. "Orders", "USD thousands", "percent of
  respondents", "days".
- A unit chart (one square per thing) is honest only when a square is a real
  thing. If 1,000 orders become 100 squares, the subtitle says "one square = 10
  orders" and a footnote says how the remainder was rounded.
- Percentages that do not sum to 100 get a footnote saying why (multi-select,
  rounding, exclusions).

## Labels

- Every mark the reader might ask "what is that?" about has a name, a value, or a
  `<title>` hover. No unlabeled series.
- Direct labels beat legends. Put the series name at the end of its line, the
  value at the end of its bar. A legend in the subtitle ("dark = this year, light =
  last year") is fine; a legend as a separate box is a last resort.
- Overlapping labels are a defect (`CH180`, and your own eyes). Thin them, stagger
  them, or move them to hover.

## Time

- Time runs left to right. Periods are evenly spaced when they are evenly spaced
  in reality; a gap in the data is a visible gap, not a joined line.
- The subtitle says the range: "Jan–Dec 2025", "last 12 weeks to 2026-08-30".
- Annotate the moment something happened ("sizing guide shipped") with a
  `ch-rule` and a `ch-t-note`, not with colour alone.

## Deltas and status

`ch-up` and `ch-down` are semantic. They pair with a sign, an arrow glyph, or a word,
so the meaning survives greyscale and colour-blindness. Never colour a bar green
because it is "good" without also saying why in text.

## Demo and placeholder data

When a gallery or example needs invented numbers, generate them deterministically
so a screenshot is stable across renders. `Math.random()` fails the linter
(`CH113`). Prefer literal arrays; if a formula is used, seed it.

Never ship a template's demo numbers, demo source line, or demo conclusion in a
user's deliverable. Every number in a delivered chart comes from the user's data.

## Disclosure

Anything the reader would feel misled by not knowing goes in `ch-card__note` or the
source line: excluded rows, a changed definition mid-series, a small sample, a
rounding rule, a mixed currency.
