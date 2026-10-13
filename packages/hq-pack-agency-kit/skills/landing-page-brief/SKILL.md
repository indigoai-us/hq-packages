---
name: landing-page-brief
description: Write the brief a designer or builder needs for one page: the buyer, the one job of the page, the message hierarchy section by section, the proof to use, the objections to answer, the form, and the data point behind each decision.
triggers:
  - landing page brief
  - brief for the new page
  - page brief
  - write the brief for
maturity: HQ-native (authored for this package)
---
# /landing-page-brief

## Inputs

The audit or the evidence brief for this client, the ICP, the CTA map, the
proof inventory, the brand guide, and the page's purpose (the person says,
or the SOW does).

## Method

Write `build/{YYYY-MM-DD}-brief-{page}.md` with these sections, each
decision followed by its data point and source in parentheses:

1. **The page's one job**: who lands here, from where, and the one action
   they take.
2. **The buyer**: one sentence from the ICP, with the count.
3. **Message hierarchy**: in order down the page, each section as a
   heading, the point it makes in one line, and the proof or data it uses.
   Hero, the problem in their words, how it works in three steps, proof,
   objections, pricing or the next step, final action.
4. **Proof**: the verified items to use, where each goes, and the
   permissions still needed.
5. **Objections**: the ones the data shows (count, rows), each with the
   true answer from the product details.
6. **The form**: fields, from `form-friction-audit` or the playbook rule.
7. **Brand**: logo, colors, fonts from the brand guide; what may not
   change.
8. **Out of scope**: what this page does not try to do.
9. **Success**: the metric and baseline from the export.

## Rules

- Every decision has a data point or is marked "judgment call" for the
  account lead to confirm.
- The brief is for one page. A second page is a second brief.
