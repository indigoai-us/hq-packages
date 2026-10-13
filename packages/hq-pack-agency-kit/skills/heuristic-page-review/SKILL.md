---
name: heuristic-page-review
description: "Review one page against the playbook's audit criteria without new data: clarity in five seconds, one primary action, proof near the claim, objections answered, form friction. Quotes the page and scores each criterion; flags what data would confirm it."
triggers:
  - review this page
  - heuristic review
  - look at this landing page
  - quick page review
maturity: HQ-native (authored for this package)
---
# /heuristic-page-review

Use when there is a page and no export yet. It is a first pass, labelled as
one; the `funnel-audit` replaces it once the data arrives.

## Method

1. Fetch the page. Save it as markdown with the URL and date.
2. Read the playbook's `audit-criteria.md`. Score each criterion from the
   page alone, on the playbook's scale, quoting the page for every score:
   - the five-second test: who is this for and what do I get, from the
     headline and subhead only
   - the primary action: list every button above the fold; more than one
     of equal weight is a finding
   - proof next to the claim: is the first proof item within one screen of
     the headline, and from whom
   - objections: security, integrations, migration, price, each answered
     within one click or not
   - the form: count the required fields
   - mobile: read it at 375 pixels wide
3. Write `reports/{YYYY-MM-DD}-page-review-{page}.md`: the scores table,
   one finding per criterion with the quote, the one change per finding,
   and **What would confirm this**: the export row or transcript that would
   turn each finding into evidence.

## Rules

- Label it "Heuristic review, no data yet" at the top.
- Every finding quotes the page; opinion about design is left out.
- Do not promise a lift. A heuristic is a hypothesis.
