# client-service knowledge

**status: landed.** `adapter-contracts.md` and `client-service.schema.yaml` are
the frozen v1 contract surface.

This is the pack's single contributed knowledge entry
(`contributes.knowledge: [client-service]`). `scan-packages.sh` links it to
`core/knowledge/public/client-service` in the installing host.

Contents:

- `adapter-contracts.md` — **landed.** The five adapter slots (`crm`, `billing`,
  `agreements`, `portal`, `transcripts`) and the operations the lifecycle skills
  call against each (e.g. `crm: resolve_dedupe_key, upsert_company, upsert_deal`
  with `mirror_stage` optional; `billing: ensure_customer, draft_invoice,
  send_invoice, billing_status`), plus the three slot states and the pointer
  binding form. Also carries the two amendments made since it was frozen: the
  `engagement_layout` block (US-008) and, from the credentialed parity run, the
  per-slot join key with its precedence order (D1), the narrowed and deferred
  `portal_status` (D2), the decision that agreement lookup will not fuzzy-match a
  client name (D3), and the recorded gap where cross-source flags stay
  firm-specific (D4).
- `client-service.schema.yaml` — **landed.** The machine-readable schema for a
  firm's `client-service.yaml`. `../../scripts/validate-config.sh` reads its
  connector enum, slot list, field lists, denylists and error catalogue directly,
  so contract and checker cannot drift.

The dual-home model — firm-internal engagement truth vs the isolated,
handover-ready client company — is documented in the pack README ("The
firm/client dual-home model") and in `skills/new-client/SKILL.md`, rather than
as a separate knowledge file here, alongside the two-phase pattern it
requires (each phase writes into one company the session holds).

## Contract rules for this corpus

- **No vendor names in the contract layer.** Slots are described only by their
  operations. A specific tool appears only in a firm's own config, or as an
  optional `recommended:` hint on an empty slot.
- Slot binding shape is `{tool_name, connector (mcp|cli|api), mapping,
  secret_name}`.
- **A binding names the join FIELD; `engagement_layout` resolves the join
  VALUE, per slot.** Keeping those apart is what stops one engagement key being
  pushed into every slot's join field — a mismatch there does not merely fail a
  read, it makes search-then-create create a duplicate.
- Secrets are referenced by **vault name only** — this pack contains zero secret
  values.
