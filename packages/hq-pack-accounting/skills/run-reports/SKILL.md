---
name: run-reports
description: Read a company's financial statements — trial balance, profit & loss (income statement), balance sheet, and account balances. Use when the user asks for their books, financials, P&L, income statement, balance sheet, trial balance, what an account's balance is, or how the business is doing financially. Reads the vault-synced accounting-projection.json.
---

# Financial reports (run-reports)

The accounting engine keeps a vault-synced **`accounting-projection.json`** for
the company — the chart of accounts with folded balances plus the three
statements, pre-computed. Read it directly; don't recompute from raw entries.

## Where the report lives

`companies/<company>/accounting-projection.json` (synced from the company vault).
If it's missing, accounting is not enabled or hasn't synced — run `/hq-sync` for
the company; if still absent, enable `accountingEnabled` in company settings.
Don't hand-total journal entries as a silent fallback.

## What it contains

| Section | Answers |
|---------|---------|
| `accounts[]` | The chart of accounts, each with `debits`, `credits`, and `balance` (normal-balance-signed). Use for "what's the balance of <account>?" |
| `trialBalance` | `totalDebits`, `totalCredits`, and `balanced` — the books tie out when these are equal. |
| `pnl` | `income`, `expense`, `netIncome`, and `byAccount[]` — the profit & loss / income statement. |
| `balanceSheet` | `assets`, `liabilities`, `equity`, `netIncome`, and `balanced` — assets equal liabilities + equity + net income. |
| `transactions[]` | Posted journal entries (for listing / drill-down). |
| `unbalanced[]` | Defensive: any entry that failed the balance check (should be empty). |

## Answering

- **"How are we doing?" / P&L** → `pnl`: revenue (`income`), `expense`, and
  `netIncome`, optionally broken out via `byAccount`.
- **"What do we own/owe?" / balance sheet** → `balanceSheet`. Confirm `balanced`
  is true; if not, surface the `unbalanced` entries rather than reporting a
  number that doesn't tie out.
- **"Do the books tie out?"** → `trialBalance.balanced`.
- **"What's the balance of <account>?"** → the matching `accounts[]` entry.
- **Date ranges** — the projection is full-history; for a period P&L, the engine
  can rebuild the projection with a date range (the builder accepts `from`/`to`
  on `entryDate`).

Always report `balanced` honestly. A real accounting system's value is that the
numbers reconcile — if they don't, that's the headline, not a rounding aside.
