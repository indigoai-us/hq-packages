---
name: review-mining
description: Mine public reviews of the client's product and its competitors (G2, Capterra, app stores, Reddit) for the language, praise and complaints that belong on a landing page. Every phrase is quoted with its source link.
triggers:
  - mine the reviews
  - what do reviews say
  - review mining
  - read the G2 reviews
maturity: HQ-native (authored for this package)
---
# /review-mining

## Inputs

The client's product name and two or three competitors from
`onboarding/inputs/competitors.md`. Review sites the person names, or G2,
Capterra and the relevant app store by default. Read only what is public.

## Method

1. Collect 30 to 60 reviews per product, newest first, with the link, date,
   rating and reviewer role when shown. Save them raw in
   `research/reviews/{product}.md` before reading.
2. Tag each review with: the outcome praised, the complaint, the switch
   ("moved from X"), the role, and any number the reviewer gives.
3. Count the tags per product. Write
   `research/{YYYY-MM-DD}-review-mining.md`:
   - **What buyers praise** about the client, ranked by count, two quotes
     each with links.
   - **What buyers complain about** for each competitor, ranked, with
     quotes: these are the objections the client's page can answer.
   - **Switch stories**: who moved from what to what, and why, quoted.
   - **Phrases to use**: fifteen verbatim phrases, grouped by headline,
     proof and objection, each linked.
   - **Phrases to avoid**: words reviewers use when they feel misled.

## Rules

- Quote with the link. A phrase without a link does not go in.
- Never quote a review on the client's page without checking the site's
  terms and the reviewer's permission; mark each quote "for research".
- Competitor complaints go on the client's page as answered objections,
  never as attacks by name.
