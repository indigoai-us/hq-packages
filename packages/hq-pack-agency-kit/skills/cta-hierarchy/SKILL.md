---
name: cta-hierarchy
description: Set one primary action per page, sized and worded for the motion that closes, with the secondary actions demoted or removed, across the whole site. Reads the CRM source column and the analytics CTA clicks; outputs a per-page action map.
triggers:
  - cta hierarchy
  - too many buttons
  - which button should be primary
  - fix the calls to action
maturity: HQ-native (authored for this package)
---
# /cta-hierarchy

## Method

1. From the CRM export, which motion closes: trial signups or demo
   requests, by count of closed-won deals per source. That is the primary
   action for the site. From the product details, confirm the trial exists
   if the data says trial.
2. Inventory every button and link styled as a button on every page: page,
   label, destination, visual weight (primary, secondary, text). Quote the
   labels.
3. Per page, decide: the one primary (the closing motion, or the step
   toward it on deep pages), at most one secondary (the other motion, as a
   text link), and the rest removed or moved to the footer. Note the
   analytics CTA click rate per page where the export has it.
4. Write `build/{YYYY-MM-DD}-cta-map.md`: the motion decision with its
   counts and rows, the per-page table (page, primary label, secondary,
   removed), and the labels: a verb and the outcome ("Start the free
   trial", "See it on your data"), never "Submit" or "Learn more".

## Rules

- One primary per page. Two of equal weight is the problem being fixed.
- The primary matches the motion that closes, not the one the client
  prefers; when they differ, say so and let the account lead decide.
