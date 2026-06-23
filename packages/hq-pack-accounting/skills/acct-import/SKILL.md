---
name: acct-import
description: Import a bank or QuickBooks CSV statement and turn each transaction into a balanced journal entry, mapping rows onto the chart of accounts. Use when the user asks to import transactions, load a bank/QuickBooks export, categorize or reconcile a statement, or bring outside transactions into the books. Drives scripts/acct-import.mjs and the account-map.json mapping.
---

# Import a statement (acct-import)

Turn a bank / QuickBooks **CSV export** into balanced double-entry journal
entries. Each statement row becomes one two-line entry: the **bank account** the
statement is for, and the **category account** resolved from the row — equal
amounts, opposite sides, balanced by construction.

## Inputs

- A CSV with (case-insensitive) columns: `date`, `description`, `amount`
  (signed; `(123.45)` or a separate `debit`/`credit` pair also work), optional
  `category`, optional `transaction id` (used as the QuickBooks id + for
  idempotent re-import).
- An **account map** at `companies/<co>/settings/accounting/account-map.json`
  (see the `account-mapping` knowledge doc): which external category /
  description maps to which internal account, plus the bank account and a
  Suspense account.

## Run

```bash
# Review first (writes nothing): see the mapped/unmapped summary.
node scripts/acct-import.mjs \
  --csv statement.csv \
  --map companies/<co>/settings/accounting/account-map.json \
  --bank "Operating Checking" --dry-run

# Post: write balanced journal-entry files into the company's ontology entities.
node scripts/acct-import.mjs --csv statement.csv --map <map.json> \
  --bank "Operating Checking" \
  --out companies/<co>/ontology/entities
```

(The script is wired to `core/scripts/` at install; invoke it from there or via
its installed path. After writing, run `/hq-sync` for the company so the engine
projects the new entries.)

## Direction of each entry

- **Money in** (positive amount) → **debit** the bank account, **credit** the
  category (e.g. income).
- **Money out** (negative amount) → **credit** the bank account, **debit** the
  category (e.g. an expense).

## Unmapped rows are surfaced, never guessed

A row whose category/description matches nothing in the map is **not posted** —
it's listed for review and the script exits non-zero. Resolve it by either:

- adding the category to the map (or a `rules[]` match), then re-running; or
- passing **`--post-mapped-only`** to route unmapped rows to the **Suspense**
  account (each flagged), so you can post the rest now and reclassify later.

## Idempotent re-import

Each entry's id is derived from the row's `transaction id` (or a hash of
date+description+amount), so re-importing the same export updates the same
entities instead of duplicating them. Re-run freely.

## Integrity

Every produced entry is balanced by construction and asserted before write — the
script will refuse to emit an unbalanced entry. The engine re-checks on
projection and lists any non-balancing entry under `unbalanced` (should always be
empty).
