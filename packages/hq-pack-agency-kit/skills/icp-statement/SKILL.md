---
name: icp-statement
description: "Write the client's ideal customer profile from the CRM export: the segment, size, title and trigger of the deals that close, and the ones that do not. One paragraph the whole site can be written to, every number from the export."
triggers:
  - write the ICP
  - who is the ideal customer
  - icp statement
  - who actually buys
maturity: HQ-native (authored for this package)
---
# /icp-statement

## Inputs

The CRM export in `onboarding/inputs/` with stage, segment, company size,
buyer title, source and lost reason. Closed-won and closed-lost deals from
the same period. Transcripts, if present, for how reps describe the fit.

## Method

1. Tabulate closed-won deals by segment, company size band and buyer title.
   The modal value of each is the ICP. Tabulate closed-lost the same way
   and by lost reason.
2. Compare the two tables. Where closed-lost concentrates (a segment, a
   size, a title, a reason like "thought it was for engineers"), that is
   the anti-profile.
3. Write `research/{YYYY-MM-DD}-icp.md`:
   - **ICP**, one paragraph: "{Title} at {segment} companies of {size},
     who {trigger}, buying {motion}." Each clause followed by its count
     ("31 of 34 closed-won, CRM export rows 2 to 35").
   - **Not the ICP**: the segments and titles that lose, with counts and
     the top lost reasons.
   - **Trigger**: what the transcripts say starts the search, quoted with
     timestamps, or "Not in the data" if there are no transcripts.
   - **What this means for the site**: who the hero names, which proof to
     show, which form to use.

## Rules

- Counts, not adjectives. "Most" is not a finding.
- One period for both tables; never compare a quarter of wins with a year
  of losses.
- Fewer than ten closed-won deals: say the sample is thin and show the
  rows.
