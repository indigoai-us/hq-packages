---
name: hero-rewrite
description: Rewrite one page's hero (headline, subhead, primary action, one proof line) for the buyer who actually closes, in the client's voice, with three options and the data point behind each. Never changes brand or invents proof.
triggers:
  - rewrite the hero
  - new headline for
  - hero options
  - fix the headline
maturity: HQ-native (authored for this package)
---
# /hero-rewrite

## Inputs

The current hero, quoted. The ICP (from `icp-statement` or the CRM export).
The customer's words (interview synthesis, review mining or transcripts).
The brand guide's voice section. The proof inventory, if there is one.

## Method

1. Name the buyer in one line from the data, with the count. Name the
   outcome they buy, in their words, with the quote and source.
2. Write three heroes. Each: headline under 10 words that names the buyer
   or their outcome; subhead under 25 words that says what it is and for
   whom; one primary action whose label matches the motion that closes
   (trial or demo, from the CRM source column); one proof line from the
   verified proof only.
3. Under each, one line: which data point it leans on and what it gives
   up. The three should differ in what they lead with (the outcome, the
   buyer, the alternative they replace), not in wording alone.
4. Write `build/{YYYY-MM-DD}-hero-{page}.md`: the current hero, the three
   options, the recommendation with its reason, and the hypothesis for
   testing it (the `hypothesis-writer` form).

## Rules

- Voice from the brand guide; words from the customers.
- No superlatives the data does not support ("fastest", "#1").
- Proof only from the verified inventory. Nothing invented.
