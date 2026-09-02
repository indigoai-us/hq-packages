# 03 — Selection

How a data shape becomes a locked template. The registry
(`types/registry.yaml`) is the roster; this file is the procedure.

## Families

| Family | Reads in | Built for | Character |
|---|---|---|---|
| **ledger** | 20–60 s | papers, long reads, annual reviews, audits | one mark per record, real units, marginalia, whitespace |
| **plain** | 10–30 s | articles, decks, memos | familiar silhouettes, countable ticks, hairlines |
| **signal** | 3–10 s | weekly reports, dashboards, status | big numbers, bold bars, deltas, status cells |

## Priority

1. **Audit ledger and plain first.** From the shape table in `00-grammar.md`, list
   every `tier: primary` type in ledger and plain that could carry the data. Compare
   at least three; if fewer than three exist, list them all. Judge on: semantic fit,
   unit honesty, whether every label fits at or above the type floor, reading
   speed against the audience, narrative tension, and whether the same silhouette
   already appears on this page.
2. **Fallback types need a written reason.** `tier: fallback` types are used only
   when no primary type can honestly encode the shape, and the delivery note says
   which primaries were considered and why each fails. "The new one looks better"
   is not a reason.
3. **Signal is a documented downgrade, not a peer.** Use signal only when ledger
   and plain both fail, or the user explicitly asks for a dashboard, weekly report,
   monitoring view, status board, or "tell me in three seconds". Record why ledger
   and plain could not carry it. When the user asks for signal, that is the reason.
4. **Out-of-roster is last.** If nothing in the registry fits, follow
   `08-authoring-a-type.md`. The new figure still inherits the nearest type's
   skeleton and every rule in this spec.

## Shapes that bypass the audit

These shapes have no honest primary encoding, so forcing a primary type would draw
the wrong chart. Go straight to the named type and say so:

| Shape | Type |
|---|---|
| Open, high, low, close per period | `plain.candles` (planned; until it ships, use `plain.line` for close plus a footnote) |
| Five-number summary with outliers | `plain.box-ticks` |
| One entity across 3–6 continuous measures | `ledger.parallel-lines` |
| A daily value for a whole year | `ledger.year-heat` |
| Composition over continuous time where the total must also read | `plain.area-stacked` |

## Lock, then compose

Before writing any page structure, for each chart record:

```
type:     plain.bar-ranked
gallery:  assets/galleries/plain.html
card:     "Sorted, labelled, one bar per category"
reason:   ≤ 15 categories × one value; which is biggest
rejected: ledger.record-rows (names are not the point), plain.ring (7 slices)
```

Only after every chart is locked do you organise the page: order, which is wide,
what the page title claims. Deciding "this page tells six things" and then
inventing figures to fit is the failure this order prevents.

## Then build from the card

Open the gallery file, find the card by its title, and start from that card's
markup. Keep its geometry, its encoding, its label placement, and its motion
classes. Replace data, labels, title, subtitle, source. Do not change the shape of
the figure to make the data look better; if the data does not fit the card, the
lock was wrong. Go back one step.

## Sibling recall

Each registry entry lists `sibling` types that answer the same question. Use them
to widen the candidate list, never to skip the family priority.
