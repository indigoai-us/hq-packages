---
name: pricing-table-copy
description: Write the pricing table from the product details only: plan names, prices, units, billing period, minimums, what each plan is for, the trial, and the one FAQ per objection the CRM shows. Shows what exists; never sets a price.
triggers:
  - write the pricing table
  - pricing page copy
  - pricing table
  - plan descriptions
maturity: HQ-native (authored for this package)
---
# /pricing-table-copy

## Inputs

`onboarding/inputs/product-details.md` for plans, prices, units, minimums,
limits and the trial. The CRM export for which plan closes most and the
lost reasons that mention price. The ICP for who each plan is for.

## Method

1. Build the plan table straight from the product details: name, price,
   unit, billing period, minimum, the three limits that differ between
   plans. Every cell traces to a line in the document; a cell with no line
   is left blank and flagged.
2. Mark the plan most closed-won deals land on (CRM count, rows) as the
   highlighted one, and write one line under each plan naming who it is
   for, in the ICP's terms.
3. Write the FAQ: one question per objection that appears more than twice
   in lost reasons or transcripts (annual versus monthly, what happens at
   the limit, how the trial ends), answered from the product details only.
4. Write `build/{YYYY-MM-DD}-pricing-copy.md`: the table, the per-plan
   lines, the FAQ, the primary action per plan (from `cta-hierarchy`), and
   the flagged blanks for the client to fill.

## Rules

- Never invent a price, a limit or a plan. Blanks are flagged, not filled.
- "Contact us" only where the product details say the plan is custom.
- No discount or anchor pricing the product details do not state.
