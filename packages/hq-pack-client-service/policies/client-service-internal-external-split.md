---
id: client-service-internal-external-split
title: The internal/external split never leaks — firm-internal state stays off every client-facing surface
when: client-service || engagement || client-portal || client-update || publish || share-artifact || proposal
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
scope: pack:hq-pack-client-service
tags: [client-service, confidentiality, engagement, adapters]
public: true
version: 1
created: 2026-08-05
source: pack:hq-pack-client-service
---

## Rule

The engagement record has two kinds of content and they are not interchangeable.

1. **Internal content never crosses a client-facing operation.** Firm-side
   coordination notes, margin and pricing strategy, likelihood or risk
   commentary, internal owner assignments, back-channel context, research
   provenance, and anything written about the client rather than to them stays in
   the internal section of `engagement.md`. It never appears in
   `publish_update`, `share_artifact`, `request_signature`, a drafted client
   message, a status update, or a CRM field the client can see.
2. **Assemble client-facing copy from client-visible sections only.** Build it up
   from the shared sections. Do **not** take the whole record and redact — a
   redaction pass fails open the first time a new internal heading is added, and
   the failure is invisible until the client reads it.
3. **`visibility` is load-bearing.** `share_artifact` carries a `visibility`
   field distinguishing client-visible from firm-internal. Set it deliberately on
   every call. When you cannot determine it, do not share.
4. **The split survives the mirror.** What goes to a CRM is stage, company
   profile and a client-safe engagement summary. Internal commentary does not
   become shareable by passing through a tool the firm happens to own.
5. **When in doubt, ask before it ships.** An approval gate is the moment to show
   the exact copy that will be published. The human approving it must be able to
   see everything the client will see.

## Rationale

A client-facing surface is a publishing pipeline, and every publishing pipeline
eventually publishes the wrong draft. The defence that actually holds is
structural: internal content lives in a section that no client-facing assembly
path ever reads, so leaking requires actively moving text rather than forgetting
to remove it.

Redaction was tried and is the weaker design. It puts the burden on remembering
every internal heading at every call site, and it fails silently and permanently
— once published, the client has seen it. Assembly from client-visible sections
fails the other way: a forgotten section is missing from the update, which is
embarrassing and fixable rather than confidential and not.

## Related

- `core/knowledge/public/client-service/adapter-contracts.md` — `publish_update` and `share_artifact`
- `client-service-engagement-is-source-of-truth`
- `client-service-approval-gate-external-actions`
