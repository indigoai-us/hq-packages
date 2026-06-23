# Double-entry rules

The invariants that make the HQ ledger a real accounting system rather than a
list of notes. The engine (`hq-pro`) enforces them; this doc is the reference the
skills post against.

## The accounts equation

```
Assets = Liabilities + Equity + (Income − Expenses)
```

Every account has a **type** and a **normal balance** — the side that increases
it:

| Type | Normal balance | Increases on | Decreases on |
|------|----------------|--------------|--------------|
| Asset | debit | debit | credit |
| Expense | debit | debit | credit |
| Liability | credit | credit | debit |
| Equity | credit | credit | debit |
| Income | credit | credit | debit |

(A *contra* account flips its type's default — e.g. Accumulated Depreciation is
an asset with a credit normal balance. Set `normalBalance` explicitly for those.)

## The rules the engine enforces

A `journal-entry` is rejected unless **all** hold (checked in integer minor units
so floating-point never makes a balanced entry look off):

- **BALANCE** — total debits equal total credits. This is the load-bearing
  invariant; it is what guarantees the books tie out and the balance sheet
  balances.
- **POSITIVITY** — every line amount is strictly positive. The `side`
  (debit/credit) carries the sign; amounts are never negative.
- **MIN_LINES** — at least two lines (every entry moves value between accounts).
- **LINE_SHAPE** — every line names an account (`accountRef` + `accountId`) and a
  side.
- **Single currency** per entry — multi-currency / FX is out of scope for now.

## Corrections: reverse, never edit

A posted entry is never edited. To fix one, post a **reversing** entry (the same
lines with debit/credit sides swapped, `reversalOf` set to the original id), then
post the correct entry. This preserves an audit trail and keeps re-runs
idempotent.

## Posting templates

| Event | Debit | Credit |
|-------|-------|--------|
| Owner invests cash | Cash (asset) | Owner's Equity |
| Earn revenue on invoice | Accounts Receivable | Income |
| Collect an invoice | Cash | Accounts Receivable |
| Record an expense paid in cash | Expense | Cash |
| Receive a vendor bill | Expense (or Asset) | Accounts Payable |
| Pay a vendor bill | Accounts Payable | Cash |
| Opening balances (day one) | each asset's opening | liabilities + equity |

Money in to a bank account is a **debit** to that account (assets increase on
debit); money out is a **credit**. The other leg is the income/expense/category
account.

## Why the balance sheet always balances

For any set of balanced entries, the sum of debit-normal balances equals the sum
of credit-normal balances (each entry contributes equal debits and credits). That
identity *is* `Assets = Liabilities + Equity + Net income`. So if every entry
balances, the statements reconcile by construction — and if they don't, there is
an unbalanced entry to find (the projection lists them under `unbalanced`).
