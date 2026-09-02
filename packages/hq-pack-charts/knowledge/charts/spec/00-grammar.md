# 00 — Grammar

The rules that do not change per chart type. Know these by heart.

## Who this is for

The person asking is usually not a programmer. They say "show me how this quarter's
conversion went, it's going in the newsletter" and never name a chart type. The job is
to translate that sentence into the right figure, and make it good enough to publish
without touching it.

## The first question

> Would a reader learn more from this than from three well-written sentences?

One number is a sentence. Two numbers are a sentence with "versus" in it. A list of
five things with no measure is bullets. Two states are a table. If the honest answer
is "a table would serve you better", say so, and offer it. That is a correct output
of `/chart` and the most under-used one.

## Data shape is the primary key

Never ask the user which chart they want. Look at the data:

| Shape | Question it answers |
|---|---|
| Categories × one value | Which is biggest, by how much |
| Periods × one value | How did it move |
| Periods × several series | Who moved differently, and did the total change |
| Parts of a whole | What share |
| Two measures per entity | Is there a relationship, where are the outliers |
| Many records, one key | What does the population actually look like |
| Many-to-one attribution | Who owns what |
| Two moments per entity | What changed |
| Start, steps, end | Where did the difference come from |
| A value with a target | Are we on track |

The shape picks the family and a shortlist of types (`03-selection.md`). The
audience and the reading time pick within the shortlist.

## One chart, one conclusion

Every card's `h2` is a **finding written as a sentence**, not a chart name and not
an axis label. "Returns fell by a third after the sizing guide shipped" is a title.
"Returns by month" is a subtitle. The subtitle carries what the marks are, the
unit, and the time range.

If a chart cannot be captioned with a sentence the reader would repeat, it does
not yet have a reason to exist.

## How many charts

The number of charts equals the number of **independent conclusions**, not the
number of columns in the sheet.

| Ask | Charts |
|---|---|
| One question, one metric | 1 |
| Two or three findings | 2–3 |
| An article, a review, a case | 4–6, covering different data shapes |

Six is the ceiling for one page. Past six, split into pages or chapters. Two
charts that say the same thing collapse into the one with the more honest encoding.
Drafts, rejected candidates, and family comparisons are process, not deliverables,
and never count.

Across a multi-chart page, allocate types globally: no silhouette twice unless
the repetition is the point (small multiples), and no chart added to reach a
count.

## The card is the unit

Every chart ships as a card with four parts in this order, and all four are
present:

1. `h2.ch-card__title` — the conclusion
2. `p.ch-card__sub` — what the marks are, unit, time range, legend in words
3. `svg.ch` — the figure, with `<title>` and `<desc>`
4. `p.ch-card__src` — source, method, date

An optional `p.ch-card__note` carries the footnote a rounding or exclusion
requires (`02-honesty.md`).

## Output is one file

One `.html` per delivery. Embedded stylesheet, inline SVG, CSS-only motion, no
JavaScript required to draw, no external images, no chart library. It renders from
`file://`, prints, and survives being archived. Webfonts are opt-in and the system
stack renders it identically offline.
