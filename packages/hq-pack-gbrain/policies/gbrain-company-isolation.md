---
id: gbrain-company-isolation
title: GBrain Company Isolation
scope: global
trigger: gbrain, brain, memory, company knowledge, capture, search
enforcement: hard
version: 1.0.0
created: 2026-06-01
updated: 2026-06-01
public: false
---

# GBrain Company Isolation

## Rule

Every GBrain runtime used by HQ MUST be scoped to exactly one HQ company unless
the user explicitly authorizes a cross-company federation for a specific task.

For default HQ usage:

- Set `GBRAIN_HOME` to `workspace/gbrain/{company}` before running `gbrain`.
- Import only that company's approved HQ paths.
- Do not mount, federate, search, or capture into another company's brain.
- Do not use a personal or global `~/.gbrain` runtime for company work.
- Do not paste secrets into GBrain pages. Use `/hq-secrets` for credentials.

If the correct company cannot be resolved, stop and ask. Guessing is a
cross-company contamination risk.

## Rationale

HQ's tenant boundary is company-first. GBrain can add synthesis, graph traversal,
and durable memory, but only if it preserves that boundary. Separate
`GBRAIN_HOME` directories make the default failure mode local and auditable.
