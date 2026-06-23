# The `external_ids` join key

Accounts are joined across source systems by an **`external_ids`** map on the
ontology entity. Each key is a provider; each value is that provider's record id
for the account.

```yaml
external_ids:
  attio: "acc_…"      # pipeline system of record
  stripe: "cus_…"     # billing
  pandadoc: "doc_…"   # contracts
  neon: "req_…"       # inbound lead database
```

## How it's populated

Each **read-only adapter** stamps its provider's id on the account when it syncs.
Adapters never mutate the source system — they read it and write the id (plus the
leg's status/value) onto the ontology entity.

## Resolution / dedup

The resolver merges records that refer to the same account using identity
precedence: **external id → normalized registrable domain → canonical name.** An
external-id match is strongest, so once an account is stamped, re-syncs update the
same entity rather than creating a duplicate.

## Extending the provider set

The provider set is defined in the ontology schema in `hq-pro` (the `ExternalIds`
type / `ExternalIdsSchema`, plus the resolver's provider list). Adding a new
source system means adding its provider key there and an adapter that stamps it —
it is a deliberate schema change, not a free-form map. (For example, the
accounting pack adds a `quickbooks` provider so imported ledger records dedupe on
their QuickBooks id.)
