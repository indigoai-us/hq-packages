---
name: sample-size-check
description: "Before a test starts, check whether the page's traffic can reach significance in a reasonable time: baseline rate, minimum detectable effect, visitors per week from the export, and the weeks needed. Says go, wait, or test something bigger."
triggers:
  - sample size
  - can we run a test here
  - how long will the test take
  - is there enough traffic
maturity: HQ-native (authored for this package)
---
# /sample-size-check

## Inputs

The page, its weekly visitors and baseline conversion rate from the
analytics export (with rows), the minimum detectable effect from the
hypothesis, two variants unless told otherwise.

## Method

1. State the inputs with their sources. A baseline not in the export is a
   stop: say what to track first.
2. Compute the sample per variant for 95% confidence and 80% power:

   n = 16 × p(1 − p) / (p × MDE)²

   where p is the baseline rate and MDE is the relative change (0.10 for
   10%). Show the arithmetic.
3. Weeks needed = (n × variants) / weekly visitors. Round up.
4. Verdict: under 4 weeks is **go**; 4 to 8 is **go, with the end date
   fixed now**; over 8 is **test something bigger** (a larger change, a
   higher-traffic page) or **wait** for traffic. Say which.
5. Append the check to the backlog row: n, weeks, verdict, date.

## Rules

- Never shorten the test by lowering confidence; change the test.
- Weekly visitors from the export, averaged over the last four weeks on
  the same page and device mix the test will use.
