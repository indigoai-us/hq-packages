---
name: chart-of-accounts
description: Set up or extend a company's chart of accounts — the list of accounts (assets, liabilities, equity, income, expenses) that transactions post to. Use when the user asks to create a chart of accounts, set up their books, add a new account, or stamp the default accounts. Creates `account` ontology entities.
---

# Chart of accounts

The chart of accounts is the set of `account` entities a company's journal
entries post to. Each account has a **type** (asset / liability / equity /
income / expense) and a **normal balance** (the side that increases it).

## Account shape

An `account` entity carries:

| Field | Meaning |
|-------|---------|
| `canonical_name` | e.g. "Accounts Receivable" |
| `accountType` | `asset` \| `liability` \| `equity` \| `income` \| `expense` |
| `normalBalance` | `debit` or `credit` — stored explicitly so a contra account can override the default |
| `accountCode` | optional number, e.g. "1100" (for ordering / familiarity) |
| `parentAccountRef` | optional relative path to a parent account (sub-accounts) |
| `currency` | ISO 4217 (e.g. "USD") |
| `openingBalance` | declared opening balance (established by a balanced opening entry — see below) |

**Normal balance by type:** assets and expenses are **debit-normal**; income,
liabilities, and equity are **credit-normal**. The default follows the type;
override `normalBalance` only for a contra account (e.g. Accumulated
Depreciation, an asset with a credit normal balance).

## Setting up

1. Start from the **`default-chart-of-accounts`** knowledge template — a
   conventional starter set (Cash, Accounts Receivable, Accounts Payable, Sales /
   Income, COGS, common expenses, Owner's Equity, Retained Earnings) with codes.
2. Create one `account` entity per line the company needs, dropping or adding to
   fit the business.
3. **Opening balances** are posted as a single **balanced opening journal
   entry** (debit each asset's opening balance, credit liabilities/equity), not
   as free-floating per-account numbers — that keeps the trial balance and
   balance sheet tied out from day one.

## Notes

- Entity ids are deterministic: `sha256("account:" + canonical_name)`. Renaming
  an account creates a new entity — pick names deliberately.
- Accounts double as the targets the **`acct-import`** account map resolves to,
  so name them the way you'll categorize transactions.
