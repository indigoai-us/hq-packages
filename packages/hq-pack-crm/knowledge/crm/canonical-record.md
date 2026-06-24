# The canonical client record

HQ's native CRM treats the **ontology as the system of record for "where is this
client?"**. Instead of asking each GTM tool at query time and stitching the
answers together, the CRM engine pre-joins them into one account entity and keeps
a vault-synced projection of the result.

## The model

- **One entity per account.** A `company` entity (optionally with `contact`,
  `deal`, `contract`, `invoice` entities) is the durable record.
- **Source legs.** Each account carries up to four joined legs — inbound origin,
  pipeline stage, contract, billing — populated by read-only adapters. A missing
  leg means that source has no data for the account, not a join failure.
- **Activity timeline.** Meetings, decisions, action items, commitments, and
  risks from the company's meeting/signal stream, attached chronologically with
  source citations.
- **Funnel stage.** The account's current pipeline stage, mirrored from the
  company's CRM system of record.

## The projection

`crm-projection.json` is the flat, queryable read-model of all accounts for a
company. It is:

- **pre-joined** — every source leg and the timeline are already merged;
- **vault-synced** — produced server-side in `hq-pro`, synced into the company
  vault, so reads are local;
- **read-only** — never write to it; mutations land in the company's source
  systems and flow back through the adapters;
- **rebuildable** — the same source entities always produce the same projection.

Shape source of truth: `repos/private/hq-pro/src/ontology/crm/projection.ts`.

## Why read it first

The cross-silo join is the expensive, error-prone part of a CRM question, and the
engine does it ahead of time. Hand-joining the source systems at query time
reproduces exactly the toil the projection removes — and risks a stale or partial
answer. Read the canonical record first; fall back to live source systems only
for brand-new inbound or for write/outreach actions.
