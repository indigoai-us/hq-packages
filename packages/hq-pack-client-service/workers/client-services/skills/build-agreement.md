---
name: build-agreement
description: Turn the engagement's commercial terms into a rendered agreement through the agreements slot, then stop. Attaching an external signer and requesting a signature are two separate approval gates. With the slot unbound, renders a draft from the firm's own template into the engagement folder; signature becomes a manual human step.
args:
  - client_slug: client key
  - template_ref: opaque reference the firm's agreements tool understands (path, id, whatever it uses) — the pack never parses it and never ships one
allowed-tools: Read, Write, Edit, Bash(bash core/workers/public/client-services/scripts/slot-state.sh:*), Bash(ls:*)
---

# build-agreement — render the agreement, stop before the send

Turns the engagement's commercial terms into a document. It does **not** send
anything. Sending is a separate, explicitly approved act, and attaching a real
person's email is a separate one before that.

## Governing policies (load and honor)

- `client-service-engagement-is-source-of-truth`
- `client-service-approval-gate-external-actions`
- `client-service-internal-external-split`

## Step 0 — resolve the agreements slot

```bash
bash core/workers/public/client-services/scripts/slot-state.sh --firm {firm} --slot agreements
```

- **bound:** use the contract operations below.
- **empty:** report `agreements slot is not configured (empty — the firm runs no
  e-signature tool)`. Render a draft **locally** from the firm's own template
  into `companies/{firm}/clients/{client_slug}/`, then stop. Signature is a
  manual human step; record in `engagement.md` where the executed copy will live.
  Surface any `recommended:` hint once and record the decline.
- **undeclared:** the same local render, reported as `agreements slot is not
  declared`, with a pointer to `/onboard-firm`. Not reported as empty.

No external writes on an unbound slot, and no error. A firm that signs agreements
by hand is a normal firm.

## Steps

1. **Read the terms** from `companies/{firm}/clients/{client_slug}/engagement.md`:
   fee, term, scope, client legal name, signer name and role, effective date,
   governing jurisdiction. Anything unconfirmed stays a `TODO` or a fillable
   field. **Never invent a term** — an invented fee in a contract is the worst
   possible place for a hallucination, and the engagement record is the only
   authority for what was agreed.

2. **Assemble the variables** from those terms. The variable set belongs to the
   firm's template, not to this pack. This pack **ships no agreement template**
   and parses no `template_ref` — a path, an id, an internal key, all opaque.

3. **Render.** `render_agreement(template_ref, variables) -> document_ref`.
   Record the returned reference. On the unbound path, render the firm's own
   template file into the engagement folder instead, with the same variables.

4. **Gate one — attaching an external signer.** Adding a real client email to the
   document is a write about a real person on an external system. Default to **no
   recipients**. Present the exact signer — name, email, role — and wait for an
   explicit approval before attaching.

5. **Gate two — requesting the signature.** `request_signature(document_ref,
   signers)` is an outbound send. Present the document, the signers and what they
   will receive, and wait for an explicit approval. Gate one does not imply gate
   two, and an approval earlier in the session does not carry.

6. **Status is free.** `agreement_status(document_ref | request_ref)` is
   read-only and never gated. Use it to confirm state instead of assuming a
   send landed.

   **Two lookup strategies, in this order, and no third one.** First an explicit
   reference recorded in `engagement.md`. Then a metadata match on the join value
   for the **agreements** slot:

   ```bash
   bash core/workers/public/client-services/scripts/engagement-layout.sh \
     --firm {firm} --engagement {client_slug} --slot agreements
   ```

   **Never fall back to matching the client's name.** A name substring is not a
   join key, it cannot be an idempotency key, and a false positive attaches
   another client's signed agreement — and therefore another client's commercial
   terms — to this engagement, silently and plausibly. This is a stated decision,
   not a missing feature (D3 in `adapter-contracts.md`).

   The consequence to report honestly: a document created outside the pack with
   no engagement metadata and no reference in `engagement.md` is **invisible**
   here. Say "not found, and here is why", then offer the two fixes — record the
   document reference in `engagement.md`, or declare the value the document
   actually carries in `engagement_layout.dedupe_keys.agreements`. Do not guess.

7. **`store_executed` is an optional capability.** Declared in
   `mapping.capabilities` → call it and record where the executed copy landed.
   `capabilities: []` → skip without attempting. Key absent → attempt and degrade
   on failure. It may resolve to a pointer location.

8. **Record in `engagement.md`:** document reference, status, whether a signer is
   attached, whether a signature was requested, and where the executed copy lives
   or will live. Commercial terms in the engagement record stay the source; the
   document is derived from them, never the other way around.

## Done when

- The agreements slot state was resolved and reported before anything ran.
- Every term in the document traces to `engagement.md`; unconfirmed terms are
  visible as TODOs or fillables rather than filled in.
- A document exists — through the slot, or locally when the slot is unbound.
- No signer was attached and no signature requested without its own approval.
- `engagement.md` records the document reference and current status.
