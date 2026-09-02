# Types — selection table

Derived from `registry.yaml`; `scripts/test-lint.py` fails if this drifts. Pick by
data shape (`spec/00-grammar.md`), then follow the audit in `spec/03-selection.md`:
ledger and plain primaries first, fallback with a written reason, signal as a
documented downgrade.

## ledger — record-level, 20–60 s

| Type | Card | Shape | Tier |
|---|---|---|---|
| `ledger.dot-strip` | One dot per record, by category | many records × one key | primary |
| `ledger.record-rows` | Every row printed, one tick per row | ≤ 60 named records × one value | primary |
| `ledger.unit-grid` | One square per unit, grouped by owner | many-to-one, ≤ 200 units | primary |
| `ledger.slope-pairs` | Before and after, one line per entity | ≤ 20 entities × two periods | primary |
| `ledger.tick-distribution` | Every observation as a tick on the line | 1–6 groups × many observations | primary |
| `ledger.event-line` | Dated events on one hairline | ≤ 40 dated events | primary |
| `ledger.small-multiples` | The same tiny chart, once per entity | 4–16 entities × short series | primary |
| `ledger.column-roster` | Names stacked under their owner | many-to-one, ≤ 50 names | primary |
| `ledger.parallel-lines` | One entity across several measures | ≤ 12 entities × 3–6 measures | fallback, bypass |
| `ledger.year-heat` | Fifty-two weeks by seven days | one daily value × a year | fallback, bypass |

## plain — familiar forms, 10–30 s

| Type | Card | Shape | Tier |
|---|---|---|---|
| `plain.bar-ranked` | Sorted, labelled, one bar per category | ≤ 15 categories × one value | primary |
| `plain.column-time` | One column per period | 6–36 periods × one value | primary |
| `plain.line` | One or two lines, end-labelled | 8–120 points × 1–3 series | primary |
| `plain.area-stacked` | Composition over time, total on top | 2–5 series over time, total must read | fallback, bypass |
| `plain.ring` | Share of a whole, one number in the middle | 2–5 parts of one whole | primary |
| `plain.scatter` | Two measures, one dot per entity | 10–300 entities × two measures | primary |
| `plain.histogram` | Counted into bins | many observations, one variable | primary |
| `plain.waterfall` | From start to end, step by step | start, ≤ 8 signed steps, end | primary |
| `plain.box-ticks` | Five-number summary with the outliers shown | 2–8 groups × five-number summary | fallback, bypass |
| `plain.candles` | Open, high, low, close | OHLC per period | fallback, bypass — **planned, no card** |

## signal — fast read, 3–10 s

| Type | Card | Shape | Tier |
|---|---|---|---|
| `signal.big-number` | The number, the delta, the range | 1–4 headline metrics with comparison | primary |
| `signal.kpi-spark` | Number, delta, and the last twelve periods | 1–6 metrics × short series | primary |
| `signal.bullet` | Actual against target, on a range | ≤ 8 measures × actual, target, range | primary |
| `signal.bar-delta` | Ranked now, and how each moved | ≤ 12 categories × value + change | primary |
| `signal.progress-ring` | How far along, one ring each | 1–6 fractions of a goal | primary |
| `signal.dumbbell` | Then and now, one bar per row | ≤ 15 rows × two values | primary |
| `signal.status-grid` | Rows by columns, each cell a state | ≤ 12 × ≤ 12 × ordinal state | primary |
| `signal.share-bar` | One bar, split by part | 2–6 parts of one whole | primary |

## sheets — report pages (`spec/06-sheets.md`)

| Sheet | File | Width | Charts |
|---|---|---|---|
| `sheet.one-pager` | `assets/sheets/one-pager.html` | 1080 flowing | 3 + KPI row |
| `sheet.monthly` | `assets/sheets/monthly.html` | 1080 flowing | 4 + KPI row |
| `sheet.brief-card` | `assets/sheets/brief-card.html` | 600 × 1000 fixed | 2 |
