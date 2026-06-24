# hq-pack-accounting

Double-entry accounting for HQ — a built-in QuickBooks replacement. Chart of
accounts, balanced journal entries, CSV/QuickBooks import with account mapping,
and the three financial statements (trial balance, profit & loss, balance
sheet), built on the same ontology your CRM uses.

## What it ships

- **`/accounting` skill** — the umbrella router: set up books, record a
  transaction, import a statement, read reports.
- **`chart-of-accounts`** — stamp a starter chart of accounts from a template.
- **`acct-import`** — import a bank / QuickBooks CSV export and map each row onto
  your chart of accounts; every row becomes a balanced journal entry.
- **`run-reports`** — trial balance, P&L, and balance sheet from the accounting
  projection.
- **`scripts/acct-import.mjs`** — the dependency-free import engine (CSV parse →
  account mapping → balanced journal entries), with an exported pure core.
- **knowledge** — the double-entry rules, a default chart of accounts, and the
  `account-map.json` mapping contract.

## How it works

The accounting **engine** lives in `hq-pro` (the deployed HQ backend), exactly
like the CRM engine:

- the ontology carries the accounting entity types — `account`, `journal-entry`,
  `ar-invoice`, `ap-bill` — alongside the CRM types;
- a journal entry holds balanced debit/credit `lines`; the engine **rejects any
  entry whose debits don't equal its credits** (the load-bearing invariant);
- a vault-synced `accounting-projection.json` folds the journal into the chart of
  accounts and the three statements;
- it is gated per company by the `accountingEnabled` setting (default OFF).

This pack ships the **experience layer** — the skills, the import script, and the
knowledge that drive the engine.

## Requires

- **`hq-pack-crm`** — accounting accounts are CRM accounts (counterparties on
  invoices/bills). The hq-cli pack-dependency gate blocks installing this pack
  until `hq-pack-crm` is installed.
- The accounting engine enabled for the company (`accountingEnabled`).

## Double-entry, briefly

Every transaction moves equal value between accounts: total **debits** always
equal total **credits**. Assets and expenses increase on the debit side; income,
liabilities, and equity increase on the credit side. Because every entry
balances, the books always tie out — and the balance sheet identity *assets =
liabilities + equity + net income* holds by construction. See
`knowledge/double-entry-rules`.

## Source of truth

[indigoai-us/hq-packages](https://github.com/indigoai-us/hq-packages)/packages/hq-pack-accounting
