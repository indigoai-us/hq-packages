# Default chart of accounts (starter template)

A conventional starter chart of accounts for a small services/SaaS business. Use
it as a starting point for **`chart-of-accounts`** — create one `account` entity
per line the company needs, dropping or adding to fit. Codes follow the usual
1000s=assets / 2000s=liabilities / 3000s=equity / 4000s=income / 5000s=COGS /
6000s=expenses convention (codes are for ordering/familiarity, not required).

| Code | Account | Type | Normal balance |
|------|---------|------|----------------|
| 1000 | Cash / Operating Checking | asset | debit |
| 1100 | Accounts Receivable | asset | debit |
| 1200 | Undeposited Funds | asset | debit |
| 1900 | Suspense | asset | debit |
| 2000 | Accounts Payable | liability | credit |
| 2100 | Sales Tax Payable | liability | credit |
| 2200 | Credit Card Payable | liability | credit |
| 3000 | Owner's Equity / Contributions | equity | credit |
| 3900 | Retained Earnings | equity | credit |
| 4000 | Sales / Services Income | income | credit |
| 4100 | Consulting Income | income | credit |
| 5000 | Cost of Goods Sold | expense | debit |
| 6000 | Rent Expense | expense | debit |
| 6100 | Payroll Expense | expense | debit |
| 6200 | Software Expense | expense | debit |
| 6300 | Marketing Expense | expense | debit |
| 6400 | Office Supplies Expense | expense | debit |
| 6900 | Bank Fees | expense | debit |

## Notes

- **Suspense (1900)** is the catch-all the importer routes unmapped rows to with
  `--post-mapped-only`. Reclassify out of Suspense once you know the right
  account, by posting a reversing/transfer entry.
- **Undeposited Funds (1200)** is a useful clearing account when a payment is
  received but not yet deposited to the bank.
- **Retained Earnings (3900)** is where prior-period net income accumulates; the
  current period's net income shows on the balance sheet as `netIncome` until
  closed.
- Name accounts the way you'll **categorize transactions** — the importer's
  `account-map.json` resolves a statement row's category to one of these account
  names.
