# Account mapping (`account-map.json`)

The importer turns each statement row into a balanced journal entry. To do that
it needs to know **which internal account** a row belongs to. That mapping lives
in a per-company settings file:

```
companies/<company>/settings/accounting/account-map.json
```

It rides the company vault ACL like any settings file, and follows the same
`settings/<integration>/config.json` pattern as other HQ integrations.

## Shape

```jsonc
{
  "version": 1,
  "baseCurrency": "USD",
  "bankAccount": "Operating Checking",   // the account a statement is FOR (default; --bank overrides)
  "accounts": {
    // external category (the CSV `category`/`type` column) → internal account NAME
    "Consulting Income": "Consulting Income",
    "Rent": "Rent Expense",
    "Office Supplies": "Office Supplies Expense"
  },
  "rules": [
    // fallback: case-insensitive substring match on the row description/memo
    { "match": "STRIPE PAYOUT", "account": "Undeposited Funds" },
    { "match": "AWS", "account": "Software Expense" },
    { "match": "PAYROLL", "account": "Payroll Expense" }
  ],
  "suspenseAccount": "Suspense"          // where --post-mapped-only routes unmapped rows
}
```

## Resolution order (per row)

1. **Exact** — `accounts[<row.category>]`.
2. **Rule** — the first `rules[]` whose `match` is a case-insensitive substring
   of the row's description/memo/name.
3. **Unmapped** — neither matched. The row is **not posted**; it's surfaced for
   review (and the importer exits non-zero) unless `--post-mapped-only` routes it
   to `suspenseAccount`.

The values on the right are **account canonical names** that must exist in the
chart of accounts (`account` entities). The importer derives each line's
`accountRef` (`../account/<slug>.md`) and deterministic `accountId`
(`sha256("account:" + name)`) from the name, so names must match your accounts
exactly.

## The QuickBooks join key

When a CSV carries a `transaction id` (QuickBooks/bank export), the importer
stamps it on the entry as `external_ids.quickbooks` and derives the entry id from
it. That makes re-import **idempotent** — re-importing the same export updates the
same entries instead of duplicating them — and lets the same account converge
with its QuickBooks record (the `quickbooks` external-id provider added in the
ontology engine).

## Maintaining the map

Treat unmapped rows as the to-do list: each import run prints the distinct
unmapped categories. Add them to `accounts` (or add a `rules` entry), then
re-run. Over a few statements the map converges and most rows post on the first
pass.
