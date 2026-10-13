---
name: competitor-teardown
description: Compare the client's site against three competitors on positioning, pricing, proof, calls to action and objection handling, page by page, and name the gap the client can own. Quotes every site; invents nothing.
triggers:
  - competitor teardown
  - compare us to
  - how do competitors position
  - competitive teardown
maturity: HQ-native (authored for this package)
---
# /competitor-teardown

## Inputs

The competitor list from `onboarding/inputs/competitors.md` (or the person
names three). The client's own site, fetched the way `site-build` does.

## Method

1. Fetch each competitor's home page, pricing page and one product page.
   Save each as markdown in `research/competitors/{name}/` with the URL and
   date at the top.
2. For each site, fill one row per dimension, quoting the site:
   - headline and who it names as the buyer
   - the one thing they claim to be best at
   - pricing: shown, from, or hidden; the plan names; the entry price
   - proof: logo count, quote count, quantified outcomes
   - primary call to action and its wording
   - objections answered above the fold (security, integrations, migration)
3. Write `research/{YYYY-MM-DD}-competitor-teardown.md`: the table, then
   one paragraph per competitor on what they are betting on, then
   **The gap**: the position no competitor holds that the client's closed-won
   data supports (check the CRM export; a gap the client cannot prove is
   not a gap). End with three changes to the client's site that follow, each
   citing the competitor row and the client data point.

## Rules

- Quote the sites as of the date fetched; they change.
- Never state a competitor's price or feature that the page does not show.
- The gap must be backed by the client's own data, not by absence alone.
