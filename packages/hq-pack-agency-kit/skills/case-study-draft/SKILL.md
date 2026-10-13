---
name: case-study-draft
description: "Draft a case study from an engagement's readouts and engagement record: the client's situation, what was changed and why, the measured result with its source, and the client's words from transcripts. Marks every claim that still needs the client's permission."
triggers:
  - case study
  - write up the results for
  - draft a case study
  - case study from the engagement
maturity: HQ-native (authored for this package)
---
# /case-study-draft

## Inputs

`engagement.md`, the readouts in `experiments/`, the audit, the before and
after from `site-build/`, and transcripts with the client's own words.

## Method

1. The result first. Take the measured change from the readout: metric,
   baseline, result, period, significance. If there is no readout with a
   significant result, stop and say the case study has no result yet.
2. Write `reports/{YYYY-MM-DD}-case-study-draft.md`, under 500 words:
   - **Who**: the client in one line (segment, size), named only with
     permission; otherwise "a {segment} company".
   - **Before**: the problem in numbers, from the audit (quoted, sourced).
   - **What we did**: two or three changes, each with the evidence it came
     from, in plain words.
   - **Result**: the readout's numbers, the period, the source.
   - **In their words**: one quote from a transcript with its timestamp,
     marked "permission needed".
3. End with the **Permissions list**: the client's name, the logo, the
   quote, the numbers, each as a line the account lead can ask about.

## Rules

- No result without a readout. No quote without a timestamp.
- Every item in the permissions list stays marked until the account lead
  records the yes in `engagement.md` under Decisions.
- Draft only; nothing is published from here.
