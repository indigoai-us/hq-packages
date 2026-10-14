---
id: client-service-engagement-is-source-of-truth
title: engagement.md is the source of truth — every client-service surface is a derived mirror
when: client-service || engagement || client-portal || deal-pipeline || invoicing || agreement || kickoff
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
scope: pack:hq-pack-client-service
tags: [client-service, engagement, source-of-truth, adapters]
public: true
version: 1
created: 2026-08-05
source: pack:hq-pack-client-service
---

## Rule

`companies/{firm}/clients/{client_slug}/engagement.md` is the single canonical
record of an engagement — contacts, timeline, stage, commercial terms, awaiting
items, decisions, internal coordination. `projects/*/prd.json` under that client
is the canonical record of delivery state. Everything else is derived.

1. **Write the engagement record first.** Any change to engagement state lands in
   `engagement.md` before it is mirrored, published, rendered or billed. A change
   made only on a derived surface is a bug, not a shortcut.
2. **Never invent an engagement fact.** If a fee, date, contact, stage, scope or
   milestone is not in `engagement.md` or a `prd.json`, it does not exist yet.
   Capture it there first (or ask), then propagate. Unknowns stay as explicit
   `TODO:` lines — never filled with a plausible value.
3. **Truth flows one way.** A CRM record, a client-facing surface, an agreement
   document and a billing object are all **derived, optional mirrors**. Data read
   back from one of them (`read_back`, `portal_status`, `agreement_status`,
   `billing_status`) may be shown to the operator and may prompt a human to fix
   the source. It may never be written into `engagement.md` as if it were source.
4. **No skill may block on a derived surface.** A CRM failure is a warning. It
   never changes engagement state, never blocks the lifecycle, and never turns
   into a retry loop that mutates the record.
5. **Unbound is not missing data.** When a slot is `empty` or `undeclared`, the
   engagement record still holds the full truth. Report the slot state and answer
   the question from the engagement files. Do not treat the absence of a tool as
   the absence of a fact.

## Rationale

The lifecycle this pack generalizes went wrong exactly once in a memorable way:
state that lived only in an external tool drifted from what the firm believed,
and the two could not be reconciled without asking the client. Fixing the
direction of truth — one file upstream, every tool downstream — is what made the
lifecycle portable in the first place.

It is also what makes the adapter contracts work at all. Three of five slots are
unbound for one of the two firms the contracts were validated against. If any
fact needed a tool to exist, that firm could not run the lifecycle. Because every
fact lives in a file the firm already owns, a fully-empty install is a complete
install, and binding a tool later adds a mirror rather than migrating the truth.

## Related

- `core/knowledge/public/client-service/adapter-contracts.md` — slot contracts and degrade paths
- `client-service-internal-external-split`
- `hq-absent-field-never-means-constraining-value`
