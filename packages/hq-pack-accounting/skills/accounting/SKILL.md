---
name: accounting
description: Double-entry accounting for a company — the umbrella entry point. Use when the user asks to set up books / a chart of accounts, record a transaction or journal entry, import a bank or QuickBooks statement, reconcile/map transactions to accounts, or read financial statements (trial balance, profit & loss, balance sheet). Routes to the focused sub-skills. Requires hq-pack-crm and the company's accountingEnabled setting.
---

# Accounting (double-entry)

The HQ accounting engine makes the ontology a real general ledger: a chart of
`account` entities and balanced `journal-entry` entities, folded into a
vault-synced `accounting-projection.json` (trial balance, P&L, balance sheet).
This skill routes a request to the right sub-skill.

## Prerequisites (check first)

1. **`hq-pack-crm` installed** — accounting accounts are CRM accounts. (The
   pack-dependency gate enforces this at install.)
2. **`accountingEnabled` for the company** — the per-company gate (default OFF),
   set via `PUT /company-settings { accountingEnabled: true }` (HQ Console). If
   there is no `accounting-projection.json` in the company vault, accounting is
   not enabled or not synced — say so rather than improvising.

## Route by intent

| The user wants to… | Use |
|--------------------|-----|
| Set up books / create a chart of accounts | **`chart-of-accounts`** |
| Record a manual transaction / journal entry | record a balanced entry (see `double-entry-rules`) |
| Import a bank / QuickBooks CSV, map transactions | **`acct-import`** |
| See trial balance / P&L / balance sheet / an account balance | **`run-reports`** |

## The one rule that matters

Every journal entry must **balance**: total debits equal total credits. The
engine rejects an unbalanced entry — never try to force one through. Corrections
are made by posting a **reversing** entry, never by editing a posted one. The
debit/credit-by-account-type table and posting templates live in the
`double-entry-rules` knowledge doc.

## Scope

Accounting data is per-company and vault-scoped. Never read or join one company's
ledger into another's context. Use `hq secrets exec --company <co> -- <cmd>` for
any source-system access; never print credentials.
