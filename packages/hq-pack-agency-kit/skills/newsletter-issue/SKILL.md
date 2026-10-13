---
name: newsletter-issue
description: "Draft one issue of the agency's newsletter from the week's work: one lesson from a readout, an audit or a teardown, written as a short story with the numbers, in the agency's voice. Anonymizes clients unless permission is recorded. Draft only."
triggers:
  - newsletter issue
  - write this week's newsletter
  - draft the newsletter
  - newsletter from the readout
maturity: HQ-native (authored for this package)
---
# /newsletter-issue

## Inputs

The agency's voice from `agency-profile.md` and `brand.md`. One source the
person picks, or the newest of: a readout in a client's `experiments/`, an
audit, a Reddit teardown. Past issues in `growth/newsletter/` for what was
already said.

## Method

1. Pick the one lesson: something the data showed that a reader could use
   on their own site this week. One per issue.
2. Write `growth/newsletter/{YYYY-MM-DD}-issue.md`, 300 to 500 words:
   - **Subject line**: under 50 characters, the lesson, no clickbait.
   - **The setup**: the situation in two lines, client anonymized ("a
     B2B SaaS company selling to ops teams").
   - **What the data said**: the numbers, from the source file, rounded
     only as much as the anonymization needs.
   - **What changed and what happened**: the change and the result, or the
     test still running.
   - **Try this**: one thing the reader can check on their own page today.
   - One line naming the agency and what it does. No offer, no link to
     book a call unless the person asks for one.
3. Say which source it came from and what was anonymized.

## Rules

- Clients are anonymous unless `engagement.md` records permission.
- Numbers from the source file only; never rounded into a better story.
- Draft only; the person sends it from their newsletter tool.
