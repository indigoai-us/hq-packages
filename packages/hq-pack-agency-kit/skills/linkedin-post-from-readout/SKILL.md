---
name: linkedin-post-from-readout
description: Turn a test readout or an audit finding into a LinkedIn post: the surprising number first, what was tried, what happened, one takeaway, under 150 words, in the agency's voice. Anonymizes the client; draft only.
triggers:
  - linkedin post
  - post about the test
  - write a linkedin post from
  - turn the readout into a post
maturity: HQ-native (authored for this package)
---
# /linkedin-post-from-readout

## Inputs

One readout (`experiments/{date}-readout-*.md`) or one audit finding, and
the agency's voice from the playbook.

## Method

1. Find the one number that would make a reader stop: the baseline and the
   change, or the leak the audit found. It comes from the file, with its
   row.
2. Write `growth/linkedin/{YYYY-MM-DD}-{slug}.md`, under 150 words, plain
   text, no hashtags unless the playbook asks:
   - line 1: the number and the situation, anonymized
   - what the site said before (quoted, short)
   - what the data said instead (the count)
   - what was changed
   - what happened, or that the test is running and when it ends
   - one takeaway the reader can act on
   - one line naming the agency
3. Offer one alternative first line.

## Rules

- A running test is described as running; never as a result.
- Clients anonymous unless permission is recorded in `engagement.md`.
- No "we got a 300% lift" without a readout that says so, with
  significance.
- Draft only; the person posts from their own account.
