---
name: invoice
description: Issue and collect customer invoices (accounts receivable) and enter and pay vendor bills (accounts payable), each posting the correct double-entry. Use when the user asks to invoice a customer, record a payment received, enter a vendor bill, pay a bill, or check who owes them / what they owe. Ties each invoice/bill to a CRM company or contact.
---

# Invoicing (AR / AP)

Customer invoices (accounts **receivable**) and vendor bills (accounts
**payable**) each post a balanced journal entry and create an `ar-invoice` /
`ap-bill` document tied to the CRM counterparty. The four actions and their
postings (canonical source: the engine's posting builders in
`hq-pro/src/ontology/accounting/posting.ts`):

| Action | Debit | Credit | Document |
|--------|-------|--------|----------|
| **Issue customer invoice** | Accounts Receivable | Income | `ar-invoice` (open) |
| **Receive customer payment** | Cash / bank | Accounts Receivable | `ar-invoice` → paid |
| **Enter vendor bill** | Expense (or Asset) | Accounts Payable | `ap-bill` (open) |
| **Pay vendor bill** | Accounts Payable | Cash / bank | `ap-bill` → paid |

## Posting an invoice/bill

1. **Resolve the counterparty in the CRM first.** The customer/vendor is a CRM
   `company` (or `contact`) — find it with the `/crm` skill and use its entity
   path as `counterpartyRef`. A single client record then spans pipeline →
   contract → billing → ledger.
2. **Write two entities** (local-first, then `/hq-sync` for the company):
   - a `journal-entry` with the balanced `lines` from the table above, and
   - an `ar-invoice` / `ap-bill` with `counterpartyRef`, `amountDue`,
     `invoiceStatus`, `issueDate`, optional `dueDate`, and `postedEntryRef`
     (the journal entry's id).
   Link them: the journal entry "Posts" the document; the document is "Posted
   by" the entry. Entity ids are deterministic
   (`sha256("ar-invoice:AR Invoice <number>")`, etc.), so re-running is
   idempotent.
3. **Write the journal entry LAST.** The ledger only reflects posted entries, so
   ordering the authoritative entry last means a crash mid-write leaves the books
   unchanged and the action safely re-runnable.

## Payments don't edit — they reverse/append

Receiving a payment or paying a bill is a **new** journal entry, plus a re-emit
of the same invoice/bill document (same id) with `invoiceStatus: "paid"` and
`amountDue: 0`. Never edit the original issue entry — that preserves the audit
trail. (To void or correct an issued invoice, post a reversing entry per the
`double-entry-rules` knowledge, don't mutate it.)

## Reading AR/AP

Outstanding receivables/payables fall out of the account balances in
`accounting-projection.json` (see the `run-reports` skill): the **Accounts
Receivable** balance is what customers owe you; **Accounts Payable** is what you
owe vendors. Per-invoice status lives on the `ar-invoice` / `ap-bill` documents
(`open` vs `paid`).

## Integrity

Every posting balances by construction (equal debit and credit). The engine
rejects any unbalanced entry, so if a posting won't balance, the inputs are
wrong — fix them rather than forcing it.
