---
name: proposal
description: Draft a client proposal from discovery notes or a call transcript, using the agency's playbook for services, pricing, voice and scope rules. Writes a scope section precise enough to become the contract, lists exclusions explicitly, and flags anything said on the call that the proposal does not cover. Draft only.
triggers:
  - write a proposal
  - draft a proposal for
  - turn this call into a proposal
  - proposal from discovery notes
maturity: HQ-native (authored for this package)
---

# /proposal

Most scope fights start in the proposal. This skill writes proposals that make
the later contract and `/client-onboarding` scope review easy.

## Inputs

- Discovery notes or a call transcript (pasted, or a file path).
- The prospect's name and a slug.
- From the playbook: `agency-profile.md` (services, pricing, voice),
  `scope-rules.md`, and `examples.md`.

Proposals for prospects live with the firm, not in a client company. Save to
`companies/{firm}/knowledge/proposals/{slug}/proposal-{YYYY-MM-DD}.md`. If the
prospect later signs, `/new-client` creates their engagement.

## Draft

1. **What we heard**: the problem and the goal in the prospect's words, with
   the call timestamps.
2. **What we will do**: services from the agency profile that fit. Name every
   brand, product, channel and deliverable count that is included.
3. **Not included**: an explicit list. Anything discussed on the call that you
   are not proposing goes here, with one line on why.
4. **How we will measure it**: the goal metric and how it will be tracked.
5. **Timeline and investment**: from the pricing model. If the playbook has no
   price for this work, leave a clearly marked placeholder. Never invent a price.
6. **What we need from you**: access, approver and documents, taken from
   `onboarding-checklist.md`, so onboarding starts complete.

Avoid optional phases that are not priced. If you suggest one, price it or
label it "not part of this proposal".

## Check before showing

List anything from the notes that the proposal does not address. Show that list
with the draft so the user can decide. Then say plainly that nothing was sent.
