---
name: ab-test-readout
description: "Write the readout for a finished A/B test from its results export: what was tested, the numbers per variant, whether the result is significant, what we learned, and what to do next. Never calls a losing or inconclusive test a win."
triggers:
  - test readout
  - write up the test results
  - how did the test do
  - ab test readout
maturity: HQ-native (authored for this package)
---
# /ab-test-readout

## Inputs

The hypothesis (from the backlog), the results export (visitors and
conversions per variant, start and end dates), and the pre-registered
metric and minimum detectable effect.

## Method

1. Check the test ran as planned: the dates, the split, the sample reached
   the size the `sample-size-check` asked for. If not, the readout says
   "inconclusive, under-powered" and stops at step 3.
2. Compute conversion rate per variant, the relative difference, and the
   significance (a two-proportion z-test is enough; state the p-value and
   the 95% interval).
3. Write `experiments/{YYYY-MM-DD}-readout-{slug}.md`:
   - **Hypothesis** as written before the test.
   - **Result**: the table, the difference, the interval, the verdict in
     one word: win, loss, inconclusive.
   - **What we learned**: one paragraph about the buyer, not the button.
   - **Next**: ship, revert, or re-test with a sharper change, and the
     hypothesis that follows.
4. Add the verdict to the backlog row and a line to the playbook's
   `learnings.md` when the result changes what the agency believes.

## Rules

- The metric is the one pre-registered. A secondary metric that moved is
  a note, not the verdict.
- Peeking early and stopping on a good day is a loss of the test, and the
  readout says so.
- Never call inconclusive "directional".
