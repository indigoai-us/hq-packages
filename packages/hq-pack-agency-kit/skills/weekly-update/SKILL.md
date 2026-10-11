---
name: weekly-update
description: Draft a client's weekly update from the engagement record, onboarding status and the past week's work. Covers what got done, what is next, what the agency needs from the client, and any risks, in the agency's voice. Draft only; the account lead approves and sends.
triggers:
  - weekly update
  - client update
  - write the weekly for
  - status update for the client
maturity: HQ-native (authored for this package)
---

# /weekly-update

## Inputs

For client `{slug}` in firm `{firm}`, read:

- `companies/{firm}/clients/{slug}/engagement.md`: Anchor, Timeline (last 7
  days), Awaiting client, Deliverables, Calls
- `companies/{firm}/clients/{slug}/onboarding/status.md`, if it exists
- any files in `companies/{firm}/clients/{slug}/` changed in the last 7 days
- `companies/{firm}/knowledge/agency-playbook/agency-profile.md` for voice

If the client has its own HQ company and the user wants work from there
included, add it to the session (`hq-session.sh add company {client-company}`)
and read only what the update needs.

Ask the user for anything else that happened this week that is not in HQ yet.

## Draft

Keep it under 250 words. Four short sections:

1. **Done this week**: outcomes, not activity. Link deliverables.
2. **Next week**
3. **We need from you**: from Awaiting client and the status file. Put
   blocking items first, with the date each was first requested.
4. **Risks**: only if there are any. Say what the risk affects and what would
   remove it.

Never include anything from the engagement's **Firm-internal coordination**
section or other internal notes (policy `client-service-internal-external-split`).
Every claim about results must come from a file you read; if you cannot point
to it, leave it out.

## Hand off

Show the draft and say it has not been sent. With the user's yes, save it to
`companies/{firm}/clients/{slug}/updates/{YYYY-MM-DD}.md` and add a Timeline line
to `engagement.md`: "Weekly update drafted." Sending is a separate step the user
approves.
