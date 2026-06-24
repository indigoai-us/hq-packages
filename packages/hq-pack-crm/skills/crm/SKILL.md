---
name: crm
description: Find any client's status from HQ's canonical client record — the native ontology CRM. Use when asked "where is this client?", "what's the status of <company>?", "show the pipeline by stage", "what's happened with <client> lately?", or "do we have a record for <company>?". Reads the vault-synced CRM projection that already joins every GTM silo (inbound, pipeline, contract, billing) plus the activity timeline onto one account record. Company-agnostic; requires the company's crmEnabled setting.
---

# CRM — the canonical client record

HQ's native CRM makes the **ontology the canonical client record**. Every
account is one entity that already joins your GTM silos — inbound origin,
pipeline stage, contract, billing — with its activity timeline (meetings,
decisions, action items, commitments, risks) attached. This skill reads that
canonical record **first**, instead of hand-joining source systems at query
time.

## Where the record lives

A per-company, vault-synced **CRM projection** (`crm-projection.json`) holds the
joined accounts. It is produced by the CRM engine in `hq-pro` and synced into the
company's vault, so the read is local and fast — no live calls to source systems.

Two ways to read it, in order of preference:

1. **`crm_*` tools** — the read-only programmatic surface over the projection,
   when the CRM MCP surface is available for your host. Shape source of truth:
   `repos/private/hq-pro/src/ontology/crm/mcp-tools.ts`.
2. **The projection file directly** — read the active company's synced
   `crm-projection.json` from its vault. Each account carries `external_ids`, the
   joined source legs, the funnel `stage`, and the `timeline`.

| Question | Read |
|----------|------|
| "Do we have a record for \<company\>?" | accounts, by name/domain |
| "Where is this client?" / "status of \<company\>?" | the full joined account record |
| "Where is every client?" / "pipeline by stage" | accounts grouped by stage |
| "What's happened with \<client\> lately?" | the account's activity timeline |

A source leg shown as **absent means missing source data**, not a join failure.

## Canonical record first

For any account-status / "where is this client?" / pipeline-shape question,
**read the canonical record before touching any source system.** The cross-silo
join is already done; reconstructing it by hand at query time is exactly the toil
this CRM removes.

Reach the source systems only for what the projection deliberately does not do:

- **Brand-new inbound** that may not be projected yet → the company's inbound
  source of truth (e.g. its lead database).
- **Writing** stage changes, notes, or imported records → the company's CRM
  system of record (the ontology is read-only inbound).
- **Outreach** — drafting/sending email, checking replies, booking state → the
  company's mail/calendar connectors.

Which specific systems back a company (CRM of record, lead database, mail,
calendar, chat) and its stage vocabulary are **company configuration**, not part
of this skill. Read the company's own CRM knowledge/policies for those.

## The join key

Accounts are joined across silos by an **`external_ids`** map on the entity
(`external_ids.<provider>` per source system). Each read-only adapter stamps its
provider's id on upsert; the resolver deduplicates by external id, then
normalized domain, then name. See the `external-ids.md` knowledge doc.

## Enabling CRM for a company

CRM is gated per company by the **`crmEnabled`** company setting. When enabled,
the engine's adapters run and the projection is produced and synced. See the
`enabling-crm.md` knowledge doc. If a company has no projection yet, CRM is not
enabled (or has not synced) for it — say so rather than hand-joining sources as a
silent fallback.

## Operating rules

1. **Canonical record first.** Read the projection (or `crm_*` tools) before any
   source system for status / "where is it?" / pipeline questions.
2. **The projection is read-only inbound.** Stage / notes / record mutations land
   in the company's CRM system of record, not the ontology.
3. **Scope to one company.** The projection is per-company and vault-scoped;
   never read or join another company's CRM data.
4. **Don't leak secrets.** Use `hq secrets exec --company <co> --only <KEY> -- <cmd>`
   for any source-system access; never print API keys or database URLs.
5. **Absent ≠ wrong.** A missing source leg means missing source data; report it
   as unknown rather than inferring.
6. **Stale or empty → say so.** If the projection is missing or stale, report
   that and offer to sync (`/hq-sync`) rather than silently falling back to a
   live hand-join.

## Output

For status questions, answer from the joined record: the account's stage, its
source legs (absent legs called out), and the recent timeline with citations.
For audits or reconciliation, produce a compact report — what was checked, what's
missing or stale, and any ambiguous cases needing judgment.
