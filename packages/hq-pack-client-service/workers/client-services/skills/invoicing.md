---
name: invoicing
description: Bill a signed engagement through the billing slot — ensure customer, draft invoice, read billing status, and (gated, and only after the same flow is proved in test mode) send. With the billing slot unbound, drafts a plain invoice into the engagement folder and stops.
args:
  - action: "draft | status | ensure-customer | send"
  - client_slug: client key
  - mode: "test | live (default: test; live touches real money and is gated)"
allowed-tools: Read, Write, Edit, Bash(bash core/workers/public/client-services/scripts/slot-state.sh:*), Bash(ls:*)
---

# invoicing — collect on a signed engagement

The billing counterpart to `build-agreement`: that one drafts the contract, this
one collects on it. It never invents commercial terms and never moves real money
quietly.

## Governing policies (load and honor)

- `client-service-billing-signed-and-test-first`
- `client-service-engagement-is-source-of-truth`
- `client-service-approval-gate-external-actions`

## Step 0 — resolve the billing slot

```bash
bash core/workers/public/client-services/scripts/slot-state.sh --firm {firm} --slot billing
```

- **empty:** report `billing slot is not configured (empty — the firm runs no
  billing tool)`. `draft` writes a plain invoice draft into the engagement folder
  and stops. `status` answers from the engagement record's billing block.
  `ensure-customer` and `send` are **not available** — say so; do not simulate
  them. Amounts owed are tracked by hand in `engagement.md`. Surface any
  `recommended:` hint once and record the decline.
- **undeclared:** the same behaviour, reported as `billing slot is not declared`
  with a pointer to `/onboard-firm`. Do not report it as empty.
- **bound:** continue.

Either way: **no external writes on an unbound slot**, and no error. An unbound
billing slot is a firm that invoices some other way, which is normal.

## Step 1 — the agreement must be signed

Live billing requires a signed agreement. Confirm it in this order:

1. `agreement_status(document_ref | request_ref)` on the agreements slot, when
   that slot is bound;
2. otherwise the executed copy recorded in `engagement.md`.

**Refuse `mode=live` for an unsigned engagement.** No approval overrides this —
the signature is the authority the billing acts on. Test mode against an unsigned
engagement is fine and is how you prove the flow.

## Step 2 — resolve terms

Fee, currency, billing contact, legal name, effective date, billing cadence and
net terms come from the signed agreement first, then `engagement.md`. Anything
unconfirmed is a blocker, not a default. Never invent an amount.

## Step 3 — mode guard, before ANY billing call

Resolve the credential named by `binding.secret_name` through the HQ secret
workflow at call time, then confirm the credential you actually hold matches the
mode you asked for and **abort on mismatch**. Print `TEST` or `LIVE` and nothing
else — never the credential, never a prefix, never a fragment. This guard runs in
test mode too.

## Step 4 — actions

| `action` | Operation | Gate |
|---|---|---|
| `ensure-customer` | `ensure_customer(key, billing_profile)` | live mode: gated |
| `draft` | `draft_invoice(customer_ref, line_items, currency)` | live mode: gated |
| `status` | `billing_status(invoice_ref \| customer_ref)` | never gated — read-only |
| `send` | `send_invoice(invoice_ref)` | **always gated**, both modes |
| `start-recurring` | `ensure_recurring_billing(customer_ref, plan{amount, currency, interval})` | **always gated**, both modes — optional capability |

`void_invoice` and `ensure_recurring_billing` are optional capabilities: declared
in `mapping.capabilities` → available; `capabilities: []` → skip without
attempting; key absent → attempt and degrade on failure.

**A retainer is not automatically recurring.** Some firms bill a monthly retainer
as a standing recurring arrangement; others bill it in arrears as a fresh one-off
invoice each month, because a recurring charge anchors to a fixed date they do
not want. Read which one from the engagement record's commercial terms. Do not
infer recurring billing from the word "monthly", and never convert an engagement
from one to the other without explicit approval — the difference is when the
client's money moves.

**Idempotency.** Every object carries the engagement's locally-derived dedupe
key **for the billing slot**:

```bash
bash core/workers/public/client-services/scripts/engagement-layout.sh \
  --firm {firm} --engagement {client_slug} --slot billing
```

The key is resolved per (engagement, slot), not per engagement — a firm's ledger
and its CRM may join on different shapes of value, and using the wrong one is not
a failed lookup but a **duplicate customer**, because search-then-create cannot
match and falls through to create. Never reuse another slot's key here, and if
the key resolves to `state: declared-none`, report it unresolved and write
nothing externally rather than substituting the slug.

Search-then-create, always. A re-run must never produce a second customer, a
second recurring charge or a duplicate invoice.

## Step 5 — test first, then live

`send_invoice` in live mode requires **all** of: a signed agreement, the same
flow already proved end-to-end in test mode this session or recorded as proved in
`engagement.md`, a passing mode guard, and an approval that named the client, the
billing contact, the amount, the currency and the due date. One approval, one
send.

## Step 6 — record the billing block in `engagement.md`

```markdown
## Billing
- Mode: test | live
- Billing tool: <the firm's own tool_name from its config>
- Customer reference: <ref>
- Amount / cadence / net terms: <from the signed agreement>
- Latest invoice: <ref> — <state> — due YYYY-MM-DD
- Source of terms: <signed agreement reference> (signed YYYY-MM-DD)
- Test-mode proof: <what was proved, when>
- Last reconciled: YYYY-MM-DD
```

Non-secret object references may be recorded. A credential, a webhook secret or
anything that authenticates may never be — not in the file, not in a log, not in
a report.

## Done when

- The billing slot state was resolved and reported before anything ran.
- Terms trace to a signed agreement; nothing was invented.
- The mode guard ran and printed only `TEST` or `LIVE`.
- Every live write had its own approval naming client, amount and consequence.
- The billing block in `engagement.md` matches what actually exists.
- On an unbound slot: a local draft exists (for `draft`), nothing was sent, and
  the report names the slot state.
