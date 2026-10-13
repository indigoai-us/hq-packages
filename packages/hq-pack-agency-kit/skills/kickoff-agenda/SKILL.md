---
name: kickoff-agenda
description: Draft the agenda for the client kickoff call from the engagement record, the proposal or SOW and the open questions: what we agreed, what we need, decisions to make on the call, and who owns what. Under one page; draft only.
triggers:
  - kickoff agenda
  - agenda for the kickoff
  - plan the kickoff call
  - first call agenda
maturity: HQ-native (authored for this package)
---
# /kickoff-agenda

## Inputs

`engagement.md` (Anchor, Awaiting client, Decisions), the proposal or SOW in
`onboarding/inputs/`, the onboarding brief's open questions if onboarding
ran, and the call length (45 minutes unless told).

## Method

1. List what is already agreed from the SOW: scope, timeline, deliverables,
   price. These are confirmed on the call, not discussed.
2. List what the agency needs from the client, from Awaiting client and
   the missing inputs, each with who has it and by when.
3. List the decisions only the client can make, from the open questions,
   each as one question with the two or three answers it could have.
4. Write `reports/{YYYY-MM-DD}-kickoff-agenda.md`, timed to the call:
   - 5 min: introductions and what success looks like, in the client's
     words
   - 10 min: what we agreed (confirm)
   - 15 min: decisions (the questions)
   - 10 min: what we need and by when (the list, with owners)
   - 5 min: how we work (the weekly update, who approves what)
   Then **Prep for us**: what to read before the call.

## Rules

- Nothing on the agenda that the SOW already settles, except to confirm.
- Draft only; the account lead sends it.
- No internal notes (margins, risks) on the client-facing agenda.
