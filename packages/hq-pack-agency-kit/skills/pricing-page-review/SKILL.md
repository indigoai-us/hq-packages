---
name: pricing-page-review
description: "Review the pricing page against what the product details say the client actually sells and what the CRM says buyers choose: plan names, the number shown, billing period, minimums, the trial, and the exit rate. Says what to show and what to drop."
triggers:
  - pricing page review
  - review the pricing
  - why is the pricing page leaking
  - pricing clarity
maturity: HQ-native (authored for this package)
---
# /pricing-page-review

## Inputs

The pricing page, `onboarding/inputs/product-details.md` (plans, prices,
minimums, trial), the CRM export (plan on closed-won deals, lost reasons
mentioning price), the analytics export (pricing page exits, CTA clicks).

## Method

1. Time the path from the home page to a number. Count the clicks. Quote
   what the pricing page shows: plan names, price, unit, billing period,
   minimums, what the trial is.
2. Compare with the product details. Every difference is a finding: a plan
   the page hides, a "contact us" where a per-seat price exists, a minimum
   the page does not state.
3. From the CRM: which plan closed-won deals land on, and how many lost
   reasons mention price, cost, "couldn't tell" or "too expensive", with
   row numbers.
4. From analytics: pricing page exit rate and CTA click rate, by device.
   The playbook's threshold (exit over 60% with no CTA click) is a clarity
   failure.
5. Write `reports/{YYYY-MM-DD}-pricing-review.md`: findings with quotes and
   rows, the plan table the page should show (from the product details
   only), the one primary action, and the metric to watch.

## Rules

- Never put a price on a page that the product details do not state.
- Never recommend a price change; that is the client's call. Recommend
  showing what exists.
