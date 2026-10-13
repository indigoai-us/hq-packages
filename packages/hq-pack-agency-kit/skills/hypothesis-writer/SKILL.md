---
name: hypothesis-writer
description: Turn an audit finding into a testable hypothesis: if we change X on page Y for segment Z, metric M moves, because the data shows D. One per finding, with the minimum detectable effect and the source.
triggers:
  - write the hypothesis
  - hypothesis for
  - turn this finding into a test
  - test hypothesis
maturity: HQ-native (authored for this package)
---
# /hypothesis-writer

## Method

For each finding the person names (or every finding in the latest audit):

1. State the change in one sentence: what, on which page, for whom.
2. State the metric that would move, the one the analytics export already
   tracks. If it is not tracked, the hypothesis is blocked and says so.
3. State the because: the data point behind it, quoted with its source
   (CRM rows, analytics rows, transcript timestamp).
4. State the baseline from the export and the smallest change worth
   detecting (ask the person if the playbook does not say; 10% relative is
   a common floor).
5. Write it in the playbook's form:

   > If we {change} on {page}, {metric} will rise from {baseline} by at
   > least {MDE}, because {evidence, with source}.

Append each to `experiments/backlog.md` with a date, a status of
`proposed`, and the finding it came from.

## Rules

- One change per hypothesis. Two changes is two hypotheses.
- The metric must exist in the export today; "engagement" is not a metric.
- No hypothesis without a quoted data point behind it.
