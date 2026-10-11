---
name: scope-check
description: Check a client request against the client's contract and the agency's scope rules. Says whether it is in scope, out of scope, or unclear, cites the contract clause, and drafts a friendly reply or a change-request outline for the account lead to approve. Never sends anything.
triggers:
  - is this in scope
  - scope check
  - client asked for something new
  - out of scope request
  - change request
maturity: HQ-native (authored for this package)
---

# /scope-check

## Inputs

- The client (`{slug}`), from the user or by asking.
- The request, pasted by the user or read from a file they name.

Read:

- `companies/{firm}/knowledge/agency-playbook/scope-rules.md`
- the contract in `companies/{firm}/clients/{slug}/onboarding/inputs/`, or the
  commercials section of `engagement.md` if there is no contract file
- the **Decisions** section of `engagement.md`, because an earlier decision may
  already settle it

If no contract or commercials can be found, say so and stop. Do not judge scope
from memory or from the proposal alone.

## Decide

Return one of:

- **In scope**: cite the clause that covers it.
- **Out of scope**: cite the clause it conflicts with, or the exclusion it hits,
  and which scope rule applies.
- **Unclear**: say what the contract does not settle and who should decide.

## Draft

- In scope: a short confirmation the account lead can send, with a rough timing.
- Out of scope: two options for the account lead: a polite decline, or a
  change-request outline (what, estimate placeholder, effect on timeline). Use
  the agency's voice from `agency-profile.md`.
- Unclear: the question to ask the client.

Everything is a draft. Say plainly that nothing was sent.

## Record

With the user's yes, append to `engagement.md` under **Decisions**:
the date, the request in one line, the verdict, and the clause.
