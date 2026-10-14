# client-services — Runbook

Operating procedure for the generic `client-services` worker. This is the source
of truth its skills follow.

The lifecycle here is not theoretical: it is the de-vendored form of a sequence
proven on real paid engagements. What was removed is every product name, every
account id, every repo path and every client. What was kept is the order of
operations and the invariants that stopped it going wrong. Each external system
is reached only through an **adapter slot** the firm declares in
`companies/{firm}/client-service.yaml`.

## Read these first

- `core/knowledge/public/client-service/adapter-contracts.md` — the five slots,
  their operations, their degrade paths. Frozen contract.
- `core/knowledge/public/client-service/client-service.schema.yaml` — the
  machine-readable encoding of the same thing.
- The four pack policies (`core/policies/client-service-*.md`) — the hard rules
  below, in enforceable form.

## The source-of-truth model

```
new-engagement     → creates companies/{firm}/clients/{slug}/ + seeds engagement.md
        │
companies/{firm}/clients/{slug}/engagement.md        ← canonical engagement state
companies/{firm}/clients/{slug}/projects/*/prd.json  ← canonical project/task state
        │
        ├─ engagement-kickoff → client KB + action tracker + capability roadmap
        ├─ track-project      → story rollup, engagement refresh, client update
        │                       └─ portal slot: publish_update  (gated)
        ├─ deal-pipeline      → stage written here first
        │                       └─ crm slot: upsert_company / upsert_deal / mirror_stage
        ├─ build-agreement    → agreements slot: render_agreement, request_signature (gated)
        └─ invoicing          → billing slot: ensure_customer, draft_invoice, send_invoice (gated)
```

`engagement.md` and the PRDs are upstream of everything. The CRM record, the
client-facing surface, the agreement document and the billing objects are
**derived views**. Never invent a fact that is not in the source, and never write
a fact read back from a derived surface into the engagement record as if it were
source.

## Slot resolution — do this before touching anything external

Every skill's first real step. One resolver, one place, three states:

```bash
bash core/workers/public/client-services/scripts/slot-state.sh --firm {firm} --slot {slot}
# or, before install / in a test:
bash <pack>/workers/client-services/scripts/slot-state.sh --config <client-service.yaml> --slot {slot}
```

| State | Written as | What it means | What you do |
|---|---|---|---|
| `bound` | `binding:` mapping, or `pointer:` | the firm runs something here | call the contract operations |
| `empty` | `binding: null`, written **explicitly** | the firm decided it runs nothing here | take the documented degrade path, surface any `recommended:` hint once, record the decline, **make no external writes** |
| `undeclared` | slot key absent, or slot present with no `binding` key | nobody ever answered this question | report `slot not declared`, **make no external writes**, suggest `/onboard-firm` |

Rules that are not negotiable:

- **`empty` is never inferred from absence.** A firm that runs no CRM writes
  `binding: null` and means it. A config that predates a slot is `undeclared`
  and gets asked, not assumed. Report them as different states, in those words.
- **An unbound slot is not an error.** It is a supported, permanent end state.
  Three of five slots are unbound for one of the two firms the contracts were
  validated against. Do not raise, do not retry, do not "helpfully" pick a tool.
- **An unbound slot makes zero writes.** Not to the CRM, not to the client-facing
  surface, not to a scratch file, not to a report that implies work happened. The
  degrade path may write to the engagement folder **only** where the contract
  says so (a local invoice draft, a local agreement draft, a dated update note),
  and only when the skill's own steps call for it.
- **An adapter failure degrades to the empty behaviour** plus a clear report. It
  never fabricates data and never silently changes engagement state.

### Degrade path per slot (from the frozen contract)

| Slot | Unbound behaviour |
|---|---|
| `crm` | engagement state stays in `engagement.md` and nothing else happens; pipeline questions are answered by reading engagement files |
| `billing` | `draft_invoice` writes a plain invoice draft into the engagement folder and stops; amounts owed are tracked by hand |
| `agreements` | `render_agreement` produces a draft in the engagement folder from the firm's own template; signature is a manual human step |
| `portal` | updates are written to the engagement folder as dated notes; nothing is published |
| `transcripts` | call notes are whatever the operator pastes into the engagement folder; no source is polled |

A `pointer` binding is **bound**, not empty. Operations a static location cannot
serve (`list_calls`, polling, live status) resolve as **unsupported** and the
skill says so instead of inventing a list.

## Approval gates

Present the exact action — what, where, and what changes for the client — and
wait for an explicit human yes. One approval covers one action; approval does not
carry forward.

Gated: `publish_update`, `share_artifact`, `request_signature`, `send_invoice`,
every live-mode billing write, every outbound message or invite, and any deploy a
binding performs internally.

Not gated: reads (`portal_status`, `agreement_status`, `billing_status`,
`transcripts_status`, `read_back`), local writes inside the engagement folder, and
test-mode billing writes — which still run the mode guard.

## Skill: `new-engagement`

Full step detail in `skills/new-engagement.md`.

1. **Resolve and guard.** Refuse to clobber an existing
   `companies/{firm}/clients/{client_slug}/` — that is an existing engagement.
2. **Research public background** (optional, public sources only). Context, never
   engagement state. Record source links under the internal section.
3. **Create the client home** under the firm. An isolated client company is
   optional and only for a client that needs its own vault or secrets.
4. **Seed `engagement.md`** from the firm's own template. Known facts filled,
   every unknown left as an explicit `TODO:`, status pre-signature until a signed
   agreement exists. Nothing invented.
5. **Portal slot** (only if `publish=true`): resolve state. Bound → assemble a
   client-safe first entry from the client-visible sections and call
   `publish_update` **behind the gate**. Empty/undeclared → write a dated note in
   the engagement folder, report the slot state, publish nothing.
6. **CRM slot** (optional): bound → `resolve_dedupe_key` locally **with
   `--slot crm`**, then `upsert_company` / `upsert_deal`. Unbound → skip and say so. A CRM failure is
   a warning; it never changes engagement state and never blocks this skill.
7. **Report** to `workspace/reports/{firm}/client-services/`.

## Skill: `engagement-kickoff`

Full step detail in `skills/engagement-kickoff.md`.

1. **Read the engagement record** and list its open TODOs.
2. **Transcripts slot.** Bound tool → `list_calls` since the window, then
   `fetch_transcript`. Bound pointer → `fetch_transcript` returns the location;
   `list_calls` is unsupported, say so, read the document. Empty/undeclared →
   report the state and work from whatever the operator has pasted into the
   engagement folder. Never fabricate a call list or a summary.
3. **Lay down the client KB**: kickoff notes, a systems-access inventory (system,
   scope, grantee, date, vault secret **name**), and a numbered action tracker
   carrying forward the engagement's open TODOs.
4. **Credential hygiene.** Any client-supplied credential goes into the vault
   through the HQ secret workflow. A credential found in a channel or a document
   is flagged for rotation, never copied into a file.
5. **Capability roadmap** as a decision queue, one question at a time. Build
   nothing speculative.
6. **Invite and training plan**, phased. Invites and access requests are outward
   actions: draft them, gate them, one approval per send.
7. **Update `engagement.md`** with roster, timeline, status and awaiting items.

## Skill: `track-project`

Full step detail in `skills/track-project.md`.

1. **Read the trackers** — every `projects/*/prd.json` under the client. Each
   story carries `passes: true|false` plus title and priority.
2. **Roll up per project**: total, passing, remaining, named in-flight stories,
   anything blocked.
3. **Update `engagement.md`** — client-visible milestones in the shared sections,
   coordination notes in the internal section.
4. **Draft the client-facing update** — plain, outcome-first, no story ids, no
   internal state. Assemble it from client-visible sections only.
5. **Portal slot** (only if `publish=true`): bound → `publish_update` **behind
   the gate**. Unbound → dated note in the engagement folder, report the state.
6. Save the rollup under `workspace/reports/{firm}/client-services/`.

## Skill: `deal-pipeline`

Full step detail in `skills/deal-pipeline.md`.

1. **Resolve the crm slot first**, before reading or writing anything.
2. **Stage is written to `engagement.md` first**, always, as the firm's own free
   text. There is no stage enum in this pack; a firm's stage vocabulary is its
   own and `mirror_stage` takes a free-text label.
3. **crm bound** → `resolve_dedupe_key` (local and pure, resolved from
   `engagement_layout` **for the crm slot** — `--slot crm` — no tool call;
   `declared-none` means unresolved, which blocks the write), then
   search-then-create: `upsert_company`, `upsert_deal`,
   `mirror_stage` if the binding declares that capability. One company, one deal;
   a re-run creates zero duplicates.
4. **crm empty or undeclared** → report the state in those words, answer the
   pipeline question by reading engagement records, and **make no writes at all**.
   Surface any `recommended:` hint once, then stop asking.
5. **`read_back` is advisory only.** It may be shown to the operator. It may
   never overwrite `engagement.md`.
6. **Never bulk-delete** anything without explicit approval.

## Skill: `build-agreement`

Full step detail in `skills/build-agreement.md`.

1. **Read the terms** from `engagement.md`: fee, term, scope, client legal name,
   signer, effective date. Anything unconfirmed stays a `TODO` or a fillable —
   never invented.
2. **agreements bound** → `render_agreement(template_ref, variables)`.
   `template_ref` is opaque; the pack never parses it and ships no template.
3. **agreements empty or undeclared** → render a draft into the engagement folder
   from the firm's own template file, report the slot state, and stop. Signature
   becomes a manual human step; record where the executed copy will live.
4. **Two separate gates.** Attaching an external signer is one approval.
   `request_signature` is another. Neither is implied by the other.
5. **Record** the document reference and status in `engagement.md`.

## Skill: `invoicing`

Full step detail in `skills/invoicing.md`.

1. **Confirm the agreement is signed** — `agreement_status`, or the executed copy
   recorded in `engagement.md`. Unsigned means no live billing, full stop.
2. **Resolve terms** from the signed agreement, then `engagement.md`. Never
   invent a fee, a billing contact or a legal name.
3. **Mode guard before any billing call.** Confirm the resolved credential
   matches the requested mode and abort on mismatch. Print `TEST` or `LIVE` only.
4. **billing bound** → `ensure_customer`, `draft_invoice`, `billing_status`.
   `send_invoice` is gated and only after the same flow has been proved in test
   mode.
5. **billing empty or undeclared** → write a plain invoice draft into the
   engagement folder, report the slot state, send nothing.
6. **Record the billing block** in `engagement.md`: mode, references, amounts,
   status, source of signed terms, last reconciled date. Non-secret references
   may be recorded; a credential never may.

## Deliberately absent in v1

- **`portal-sync`** — the old repo-shaped skill (edit a site config, build,
  deploy). The frozen portal contract is operation-shaped, so there is no
  build/deploy operation to drive, and the publish is one gated call the other
  skills already make. A separate sync skill would be a second writer to the same
  slot.
- **`call-monitor`** — needs polling plus a messaging surface. `list_calls` is
  unsupported for pointer bindings, and a messaging surface is not one of the
  five v1 slots. `engagement-kickoff` reads transcripts on demand instead.

Rationale in full, plus the conditions for revisiting each, is in `worker.yaml`
under `deferred_adapters`.

## Safety invariants

- `engagement.md` and `prd.json` are the only sources of truth. No invented facts.
- Three slot states, always distinguished; `empty` never inferred from absence.
- An unbound slot reports and makes no writes. It is never an error.
- Firm-internal state never crosses a client-facing operation.
- Every publish, send, signature request, invite and live billing write is gated.
- Billing is signed-only, test-first, and environment-verified.
- Every external write carries the locally-derived join key **for that slot**;
  re-runs duplicate nothing. An unresolved key blocks the write instead of
  falling back to a value the slot cannot join on.
- Tenant isolation: one firm, one client, one set of configured services.
- Secrets by vault name only, resolved at call time, never printed.

## Verification

`worker.yaml` defines three post-execute checks: `engagement_grounded`,
`approval_gate_passed`, and `slot_degradation_clean`. Each names what fails it.
Run them against your own output before reporting a lifecycle skill complete.
