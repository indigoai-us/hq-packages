# hq-pack-crm

Native HQ CRM, packaged. Turns your **ontology into the canonical client
record** and gives agents a fast, read-only way to answer "where is this
client?" without hand-joining your GTM silos at query time.

## What it ships

- **`/crm` skill** — the canonical-record-first workflow: query the joined
  account record (inbound origin, pipeline stage, contract, billing, and the
  activity timeline) before reaching into any source system.
- **`crm` knowledge** — the canonical-record model, the `external_ids` join key,
  and how to enable CRM for a company.

## How it works

The CRM **engine** lives in `hq-pro` (the deployed HQ backend), not in this
pack. The engine:

- adds the CRM entity types to the ontology (`contact`, `deal`, `contract`,
  `invoice`) alongside `person` / `company` / `project` / `concept`;
- runs read-only adapters that stamp each account with an `external_ids` join
  key per source system;
- regenerates a vault-synced **`crm-projection.json`** that joins every silo
  onto one account, with the meetings/signals activity timeline attached;
- exposes the read-only `crm_*` tools over that projection.

This pack ships the **experience layer** — the skill and knowledge that drive
the engine. It is company-agnostic: the per-company `crmEnabled` setting turns
the engine on, and the skill reads whatever the active company's projection
contains.

## Requires

- `hqCore >= 12.0.0`
- The native ontology CRM enabled for the company (`companySettings.crmEnabled`),
  which produces the `crm-projection.json` the skill reads.

## Source of truth

[indigoai-us/hq-packages](https://github.com/indigoai-us/hq-packages)/packages/hq-pack-crm
