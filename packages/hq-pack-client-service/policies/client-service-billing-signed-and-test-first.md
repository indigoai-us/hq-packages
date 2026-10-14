---
id: client-service-billing-signed-and-test-first
title: Billing is signed-only and test-first — no live money action without a signature, a proved test run, and a mode guard
when: client-service || invoicing || invoice || billing || retainer || payment
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
scope: pack:hq-pack-client-service
tags: [client-service, billing, money, approval, adapters]
public: true
version: 1
created: 2026-08-05
source: pack:hq-pack-client-service
---

## Rule

1. **Signed only.** A live billing write requires a signed agreement for that
   engagement, confirmed through `agreement_status` on a bound agreements slot or
   through the executed copy recorded in `engagement.md`. No approval overrides
   this — the signature is the authority the billing acts on, and a human saying
   "go ahead" is not a contract.
2. **Test first.** Prove the whole flow in test mode before the same flow runs
   live: customer, invoice draft, status read. Record what was proved and when in
   the engagement record's billing block. A live run whose test equivalent has
   never succeeded does not happen.
3. **Mode guard before any billing call, including test.** Resolve the credential
   named by `binding.secret_name` through the HQ secret workflow at call time,
   confirm it matches the mode that was requested, and **abort on mismatch**.
   Print `TEST` or `LIVE` and nothing else — never the credential, never a
   prefix, never a fragment, never in a log or a report.
4. **Per-action approval in live mode.** Each live write is presented on its own
   with client, billing contact, amount, currency, terms and due date, and waits
   for an explicit yes. `send_invoice` is gated in **both** modes.
5. **Terms come from the signed agreement, then the engagement record.** Never
   from a proposal, a call summary, a message, or an inference. An unconfirmed
   amount is a blocker, not a default.
6. **Idempotency is a money-safety property.** Every billing object carries the
   engagement's locally-derived dedupe key; search-then-create, always. A re-run
   must never create a second customer, a second recurring charge, or a duplicate
   invoice. If you cannot search first, do not write.
7. **Scope every read and write to this engagement.** A billing account is
   usually shared with the firm's other products and customers. Filter by the
   engagement's key. Never read, mutate, void or cancel an object you did not
   create for this engagement.
8. **Unbound billing slot: draft locally and stop.** Write a plain invoice draft
   into the engagement folder, report the slot state, and send nothing.
   `ensure_customer` and `send_invoice` are unavailable, not simulated.

## Rationale

Billing is the one place in the lifecycle where a mistake costs the firm its
client rather than an afternoon. Each clause here corresponds to a way it goes
wrong: charging before the contract exists, discovering in production that the
flow was never exercised, running a live call with a test credential (or worse,
the reverse), and re-running a script that quietly creates a second subscription.

Signature-before-money is the clause that is most often argued with, and it is
the one that must not bend. Every other guard protects against a mistake; this
one protects against a decision — and if the terms are genuinely agreed, getting
them signed costs less than the conversation that follows an unauthorized charge.

## Related

- `core/knowledge/public/client-service/adapter-contracts.md` — the `billing` slot
- `client-service-approval-gate-external-actions`
- `client-service-engagement-is-source-of-truth`
- `credential-access-protocol`
