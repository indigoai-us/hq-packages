---
name: test-prioritization
description: Rank the experiment backlog by expected lift, confidence in the evidence and ease of building, the playbook's way, and output the ordered list with the reasoning per row. Reads the backlog; never scores a test without evidence.
triggers:
  - prioritize the tests
  - which test first
  - rank the backlog
  - test prioritization
maturity: HQ-native (authored for this package)
---
# /test-prioritization

## Inputs

`experiments/backlog.md` (from `hypothesis-writer` or the audit), the
analytics export for page traffic, and the playbook's ranking rule (default:
expected lift multiplied by ease).

## Method

1. For each hypothesis, score three things on 1 to 5, each with a reason:
   - **Lift**: how much the metric could move, from the size of the leak
     in the export (traffic on that page times the drop).
   - **Confidence**: how strong the evidence is. Two sources that agree
     (CRM and transcripts) score 5; one heuristic scores 2.
   - **Ease**: copy change 5, layout change 3, new page or integration 1.
2. Multiply lift by ease, break ties by confidence. Low-traffic pages drop
   regardless of lift: the `sample-size-check` says whether a test can
   finish there at all.
3. Write `experiments/{YYYY-MM-DD}-priorities.md`: the ranked table with
   the three scores and the one-line reason for each, the top five marked
   `next`, and the ones parked with why.

## Rules

- Scores are explained or they are not scores.
- Never rank a hypothesis that has no metric or no evidence; send it back.
- One page gets one running test at a time.
