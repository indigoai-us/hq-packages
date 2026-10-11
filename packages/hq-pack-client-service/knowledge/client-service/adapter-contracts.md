# Adapter contracts — the five slots

**Status: frozen for v1 (US-002), amended twice — once by the first-install
dogfood (US-008), once by the credentialed parity run (D1–D4).** The first
amendment added `engagement_layout`, the `stage_labels` mapping key, the
`ensure_recurring_billing` optional capability, and the tracker story shape. The
second added `engagement_layout.dedupe_keys` (a join key **per slot**, D1),
narrowed and deferred `portal_status` (D2), and wrote down two decisions that
were previously accidents rather than choices (D3, D4). Every addition is
additive and optional; no existing config changes meaning, and every frozen
example still validates unchanged. This file is the contract layer. It defines
what the client-service lifecycle skills are allowed to ask an external tool to
do, and nothing else. `client-service.schema.yaml` is the machine-readable
encoding of the same thing; `../../scripts/validate-config.sh` enforces it.

## The one rule that generates all the others

**No vendor is named in the contract layer.** A slot is defined by the operations
the lifecycle needs, never by a product. The only place a product name may appear
in this pack is:

1. inside a firm's own `client-service.yaml`, as `binding.tool_name` — the firm's
   choice, opaque to the pack; or
2. as a `recommended:` hint on an **empty** slot, which skills surface as a
   suggestion and never as a requirement.

Everything below follows from that. If an operation can only be implemented by
one product's data model, the operation is wrong, not the product.

## Slot states — empty is a first-class state

Every slot resolves to exactly one of three states. They are different, and the
difference is load-bearing.

| State | How it is written | What it means | Lifecycle behaviour |
|---|---|---|---|
| `bound` | slot key present, `binding:` present with a mapping | the firm runs a tool here | call the operations |
| `empty` | slot key present, **`binding: null` written explicitly** | the firm has decided it runs no tool here | degrade to the documented local behaviour, surface any `recommended:` hint once, make no external writes |
| `undeclared` | slot key absent, **or** slot present with no `binding` key at all | unknown — this config never spoke to the question | report "slot not declared", make no external writes, suggest `/onboard-firm`; do **not** treat as a decision |

`empty` is never inferred from absence. A firm that has no CRM writes
`binding: null` and means it. A config that simply predates the CRM slot is
`undeclared` and gets asked, not assumed. That distinction is the whole reason
this table exists — see "Absent is not a value" below.

An `empty` slot is a supported, permanent end state. Three of the five slots are
empty for the second validation firm (see `../../examples/README.md`). A firm
whose config is empty in every slot must still be able to install the pack and
run every lifecycle skill.

## Binding shape

A bound slot carries exactly this shape — four keys, no more:

```yaml
binding:
  tool_name: <opaque firm-chosen label>      # required
  connector: mcp | cli | api                 # required
  mapping: { ... }                           # optional, adapter-specific
  secret_name: <vault name>                  # optional, NAME ONLY, never a value
```

- **`tool_name`** is a label, not an enum. The pack never branches on it. It
  exists so operators and logs can say which thing was called.
- **`connector`** is the transport only: an MCP server, a local CLI, or a direct
  HTTP API. It says nothing about the vendor.
- **`mapping`** translates contract vocabulary into the tool's vocabulary. It is
  free-form; the pack reads only the reserved keys listed below and ignores the
  rest, so a firm may keep its own notes there and a newer pack version may add
  reserved keys without breaking an older config.
- **`secret_name`** names a vault secret. The pack resolves it through the HQ
  secret workflow at call time. A binding that inlines a credential is a
  validation error, not a warning. Three states, same idiom as the slot itself:
  a name is **declared**, **absent is undeclared** and the skill asks rather than
  assuming an unauthenticated call is fine, and **`secret_name: null` written
  explicitly is declared-none** — this binding needs no vault credential, so
  stop asking. The third state was added by the dogfood: a binding to a
  capability the host platform already authenticates has no secret to name, and
  without it such a firm gets asked for a credential that does not exist.

### Reserved `mapping` keys

| Key | Meaning |
|---|---|
| `capabilities` | list of *optional* operations this binding supports. **Absent means undeclared, not unsupported** — see below. |
| `dedupe_field` | which remote field carries the join key **in this slot's tool**. It names the *field*, never the *value*; the value is resolved per (engagement, slot) by `engagement_layout` — see "Join keys" below. |
| `objects` | contract-noun → tool-noun renames (e.g. `deal: opportunity`) |
| `defaults` | per-operation default arguments the firm always wants |
| `stage_labels` | engagement-record stage label → the label this tool expects. Added by the dogfood: a firm's engagement vocabulary and its CRM's configured stage options are usually two different vocabularies, and `mirror_stage` was silently assuming they were one. Absent means undeclared — pass the engagement label through unchanged and degrade on failure, never invent a mapping. |

### Pointer bindings — when the "tool" is a place

Not every source is a service. Some firms' answer to "where do call records live"
is a document a human maintains. A slot may therefore be bound by a **pointer**
instead of a tool binding:

```yaml
transcripts:
  pointer:
    kind: document | folder | url            # required
    location: <path, vault path, or URL>     # required
    maintained_by: human | automation        # optional
    note: <free text>                        # optional
```

A pointer is a `bound` state, not an `empty` one — the firm has answered the
question. Operations that cannot be served from a static location (listing,
polling, status) resolve as unsupported and the skill says so instead of
inventing data. A slot carrying **both** `binding` and `pointer` is an error;
they are alternative bindings, not layers.

Pointers are meaningful on `transcripts`, `portal`, and `agreements`. They are
accepted on any slot, because forbidding them elsewhere would only encode a guess
about how firms work.

## Absent is not a value

Policy `hq-absent-field-never-means-constraining-value` applies to every optional
field in this schema, and the contract layer is written so that it can.

- Read **presence** and **value** separately. `has(key)` first, value second.
  Never `value // default` where the default constrains behaviour.
- **Absent → unknown → add no constraint.** The safe resolution of "unknown" is
  to make no external write and tell the operator the field is undeclared. It is
  never to assume a decision the firm did not make.
- **`mapping.capabilities` absent** does **not** mean "supports nothing". It means
  undeclared: the skill attempts the optional operation and degrades gracefully on
  failure. `capabilities: []` written explicitly means "declared, none" and the
  skill skips without attempting.
- **`recommended.required` absent** resolves to `false`. The non-constraining
  direction is the only permitted one; a recommendation may never be marked
  required, and the validator rejects `required: true` outright.
- **Unknown keys are tolerated in both directions.** A slot name, mapping key, or
  capability this pack version does not recognise produces a warning, never an
  error. A config written by a newer pack version stays loadable by an older one,
  and a config written by an older pack version stays loadable by a newer one.
  Neither direction may be made safe by "deploy A before B".

## Engagement layout — where the record and its trackers live

**Added by the first-install dogfood (US-008), and the only change to this file
since it was frozen.** The rest of the contract survived contact with a real
firm; this part did not.

The v1 draft hard-coded two paths into the lifecycle skills:
`companies/{firm}/clients/{slug}/engagement.md` for the canonical record, and
`companies/{firm}/clients/{slug}/projects/*/prd.json` for the project trackers.
The first real install broke both immediately. That firm's engagements live in
three different trees, none of its project trackers sit under the engagement
folder, and at least one engagement joins to its billing and agreement records
by an alias rather than by its slug.

Those are not vendor facts. They are facts about how a firm files its own work,
and the pack had quietly assumed one answer to a question it never asked. The
fix is therefore a **declaration**, not a branch:

```yaml
engagement_layout:
  engagement_path: 'companies/{firm}/clients/{slug}/engagement.md'
  tracker_sources:
    - 'companies/{firm}/projects/*/prd.json'
  dedupe_key: '{slug}'
  dedupe_keys:                         # per SLOT — see "Join keys" below
    <slot>: <key>
  overrides:
    <engagement-slug>:
      engagement_path: <path>          # this one lives somewhere else
      tracker_sources: [<glob>, ...]   # this one is tracked somewhere else
      dedupe_key: <key>                # this one joins by an alias
      dedupe_keys:                     # ...except in these slots
        <slot>: <key>
      note: <free text>
```

Rules:

- **The whole block is optional and so is every field in it.** Absent resolves to
  the v1 defaults above, so a config written before this existed behaves exactly
  as it did. Absent is undeclared, and undeclared resolves to *a default path*,
  which names a file without asserting the firm keeps anything in it.
- **`tracker_sources` is a list**, because a firm may keep trackers in more than
  one tree. `tracker_sources: []` written explicitly is **declared-none**:
  `track-project` reports "no tracker" and never guesses a percentage. That is a
  different state from absent, and the two are never collapsed.
- **Resolution is most-specific-first**: an override entry, then the firm-level
  layout, then the pack default — per field, not per block. An override that
  names only `dedupe_key` still inherits the firm's `engagement_path`.
- **Only `{firm}` and `{slug}` are substituted.** These are path templates, not a
  language.
- `resolve_dedupe_key` stays **local and pure**. Declaring an alias does not make
  it a tool call; it makes the local computation correct.
- Resolve it with
  `workers/client-services/scripts/engagement-layout.sh --firm {firm} --engagement {slug}`,
  which is read-only by construction, the same way `slot-state.sh` is. No skill
  may re-derive these paths by hand.

The older top-level `engagement_source_of_truth` key is untouched and still
valid. It is prose that records which file is canonical; `engagement_layout` is
the resolvable form. When both are present, the layout wins.

## Join keys — one value per (engagement, slot)

**Added by the credentialed parity run (D1). This is the second and last change
to this file since it was frozen.**

`mapping.dedupe_field` was always declared **per slot** — it names the remote
field each tool joins on. The value that went into it was resolved **per
engagement**. So the contract carried an unstated assumption: that one key value
is valid in every slot's join field. That assumption is false for a firm whose
slots join on different *shapes* of value — a short alias in the ledger and the
agreements tool, a registrable domain in the CRM. No single string is both.

The read-side symptom is a rejected lookup, and that is the small half.
**The write-side consequence is the reason this was P1.** Every write in this
contract is `search-then-create`. A search on a value the field cannot accept
cannot match the record that already exists, so the write falls through to
create — and produces a **duplicate**. That is precisely the failure the
idempotency rule exists to prevent, and it happens on the first live run, before
anybody notices the read was broken.

The fix is a **declaration, not a branch**, in the same shape as the rest of
`engagement_layout`. `dedupe_keys` is a map keyed by **slot name**, legal at the
firm level and inside any override entry. The pack still resolves **exactly one**
join value per (engagement, slot); it just stops assuming there is only one key
for all slots. No vendor appears — these are keys in the firm's own vocabulary,
keyed by contract slot name — and `resolve_dedupe_key` stays **local and pure**:
declaring a second key does not make it a tool call.

### Precedence — read it in this order, every time

Two axes. **Scope first**, then **slot-specificity within a scope.**

| # | Declared at | Means | `source` reported |
|---|---|---|---|
| 1 | `overrides.<slug>.dedupe_keys.<slot>` | this engagement, this slot | `override-slot` |
| 2 | `overrides.<slug>.dedupe_key` | this engagement, every slot that names no key of its own | `override` |
| 3 | `dedupe_keys.<slot>` | this firm, this slot | `firm-slot` |
| 4 | `dedupe_key` | this firm, every slot that names no key of its own | `firm` |
| 5 | `{slug}` | the pack default | `default` |

Scope outranks slot because that is the rule `engagement_layout` already
promised — *"an override entry, then the firm-level layout, then the pack
default"* — and inverting it for one field would be a second, unstated rule.
Within a scope, a key named for a slot is the narrower statement and wins.

**Presence is read before value at every level.** An absent level is skipped, not
resolved into a decision.

### Backward compatibility, in both directions

- A config with a single `dedupe_key` and **no `dedupe_keys` anywhere** can only
  reach levels 2, 4 and 5 — the exact three levels that existed before this key
  was added. Every slot resolves to the same value it resolved to before, for
  every engagement. Nothing about it changes.
- A config with **no `engagement_layout` at all** reaches only level 5.
- **Absent is never a constraint and never an error.** A slot that names no key
  of its own is not "unjoinable"; it inherits.
- An **older** validator reading a config that uses `dedupe_keys` reports
  `W_LAYOUT_FIELD_UNKNOWN` and loads it, exactly as the compatibility contract
  requires. Neither direction is made safe by ordering an upgrade.

### `dedupe_keys.<slot>: null` — declared-none

Written **explicitly** as null, an entry is **declared-none**: this slot has no
join value derivable at this level. The caller reports the key as **unresolved**
and makes **no external write**. It does *not* fall through to the general key.

This is the same idiom as `binding: null`, `secret_name: null` and
`tracker_sources: []`, and here it is the load-bearing safety property: a firm
whose CRM joins on a value that cannot be derived from a slug writes
`dedupe_keys: {crm: null}` at the firm level, and a new engagement that has not
yet declared its own value resolves to *unresolved* instead of quietly sending a
slug into a field that cannot hold one. Unresolved blocks a write; a wrong value
creates a duplicate. Absent still means undeclared, and the two stay distinct.

### The one ambiguous combination, named on purpose

Level 2 outranks level 3. So an engagement that declares a **general**
`dedupe_key` shadows a **firm-level per-slot** key for that engagement, and that
slot joins on the general value. That is defined behaviour, and it is also
exactly how this defect comes back. The validator therefore warns by name —
`W_LAYOUT_DEDUPE_KEY_SHADOWS_SLOT` — naming the engagement and the slot. The
warning is silenced by declaring the slot's key on the override entry (level 1),
which is where an engagement that needs two different join values should say so
anyway. It is a warning, never an error: the config is legal and its behaviour is
defined.

### Resolving it

```bash
workers/client-services/scripts/engagement-layout.sh \
  --firm {firm} --engagement {slug} --slot {slot}
```

Read-only by construction, like `slot-state.sh`. **No skill may re-derive a join
key by hand, and no skill may reuse one slot's key in another slot.** Called
without `--slot` the resolver reports the general key only, exactly as it did
before this existed; if the engagement resolves a different key for some slot it
says so (`dedupe_keys_declared`) rather than letting a caller use the wrong one
by accident.

## Project trackers — story shape

`track-project` reads `passes` out of each story in a tracker file. Two details
the dogfood forced into the contract, because real tracker files vary:

- The story array is `userStories` **or** `stories`. A tracker that uses the
  other name is not a tracker with no stories — read whichever key is present,
  and if both are, read `userStories`.
- A story with **no `passes` key is undeclared, not failing.** Report it as
  undeclared and count it separately. Resolving absent to `false` would let an
  untracked story silently read as a failure, which is exactly the constraint
  that `hq-absent-field-never-means-constraining-value` forbids.

## Slot 1 — `crm`

**Derived mirror. Never the source of truth.**
`companies/{firm}/clients/{slug}/engagement.md` is the source of truth for every
engagement fact, including stage. The CRM is an optional, write-mostly projection
of that file. No lifecycle skill may block on the CRM, and a CRM failure is
reported as a warning — it never changes engagement state.

This is the correction the second-firm walk forced: the draft contract made
`set_stage` load-bearing, which silently assumes a deal-stage pipeline exists.
A firm with no CRM has no pipeline, and a firm with a contact-only CRM has no
stages. Stage lives in `engagement.md`; mirroring it is optional.

| Operation | Signature | Required of a binding |
|---|---|---|
| `resolve_dedupe_key` | `(engagement, slot) -> key` | yes — but **local and pure**. Resolved from `engagement_layout` and the slug, no tool call. The binding declares which remote *field* carries it (`mapping.dedupe_field`); `engagement_layout` resolves the *value*, per slot. It is the idempotency key on every write below, so a key that resolves to `unresolved` (declared-none) **blocks the write** — see "Join keys". |
| `upsert_company` | `(key, company_profile) -> record_ref` | yes |
| `upsert_deal` | `(key, engagement_summary) -> record_ref` | yes |
| `mirror_stage` | `(record_ref, stage_label) -> void` | **optional capability.** `stage_label` is free text from `engagement.md`, not an enum. A tool with no pipeline model simply does not declare it. If the binding declares `mapping.stage_labels`, translate the engagement label through it before the call; a label with no entry is passed through unchanged and a failure is a warning. |
| `read_back` | `(record_ref) -> record` | **optional capability.** Advisory only. A read-back may be shown to the operator; it may never overwrite `engagement.md`. |

**Empty behaviour.** Engagement state stays in `engagement.md` and nothing else
happens. Pipeline questions are answered by reading the engagement files. The
firm is told once that a CRM slot exists and is unbound.

## Slot 2 — `billing`

Drafting and sending are separate operations on purpose: sending money requests
to a client is an irreversible external action and sits behind an explicit
approval gate, test-mode first.

| Operation | Signature | Required of a binding |
|---|---|---|
| `ensure_customer` | `(key, billing_profile) -> customer_ref` | yes |
| `draft_invoice` | `(customer_ref, line_items, currency) -> invoice_ref` | yes |
| `send_invoice` | `(invoice_ref) -> void` | yes — **gated**: never called without explicit human approval in-session |
| `billing_status` | `(invoice_ref \| customer_ref) -> {state, amount_due, currency, as_of}` | yes — read-only |
| `void_invoice` | `(invoice_ref) -> void` | **optional capability** |
| `ensure_recurring_billing` | `(customer_ref, plan{amount, currency, interval}) -> recurring_ref` | **optional capability — gated.** Added by the dogfood. The v1 draft could only express one-off invoices, so a firm on a monthly retainer had no way to declare recurring billing at all and had to reach around the slot. Idempotent: search before create, one recurring arrangement per customer per plan. Every rule for `send_invoice` applies — explicit in-session approval, test mode proved first. A firm that only ever sends one-off invoices declares nothing and is unaffected. |

**Empty behaviour.** `draft_invoice` degrades to writing a plain invoice draft
into the engagement folder and stopping. Nothing is sent. Amounts owed are
tracked in `engagement.md` by hand.

## Slot 3 — `agreements`

| Operation | Signature | Required of a binding |
|---|---|---|
| `render_agreement` | `(template_ref, variables) -> document_ref` | yes. `template_ref` is opaque — a path, an id, whatever the firm's tool uses. The pack never parses it and never ships one. |
| `request_signature` | `(document_ref, signers) -> request_ref` | yes — **gated** external send |
| `agreement_status` | `(document_ref \| request_ref) -> {state, signed_at, signers}` | yes |
| `store_executed` | `(document_ref) -> artifact_ref` | **optional capability.** Where the executed copy lands. May resolve to a pointer location. |

**Empty behaviour.** `render_agreement` produces a document draft in the
engagement folder from the firm's own template file. Signature becomes a manual
human step, and the executed copy's location is recorded in `engagement.md`.

### How `agreement_status` finds a document — decided, not omitted (D3)

The credentialed parity run noticed that the firm-specific worker this pack
replaces had **three** lookup strategies and the pack has **two**. The missing
third was a substring match on the client's name. That difference was an
accident; this is the decision.

**In scope, in this order:**

1. an explicit `document_ref` or `request_ref` recorded in the engagement record;
2. a metadata match on the join value for the `agreements` slot — the value
   resolved by `engagement_layout` (per slot, see "Join keys"), in the field
   named by `mapping.dedupe_field`.

**Deliberately out of scope: a fuzzy match on the client's name.** Not "not yet";
not at the contract layer.

- A name substring is **not a join key**, so it cannot be an idempotency key, and
  every other lookup in this contract is an idempotency key.
- A false positive attaches the **wrong executed agreement**, and therefore the
  wrong commercial terms, to an engagement. This pack already says an invented
  fee in a contract is the worst place for a hallucination; silently returning
  another client's signed document is the same failure with a paper trail.
- It fails **silently and plausibly**: the document it returns looks right. Two
  similarly named clients are common, and a firm with a parent and a subsidiary
  has them by construction.

**The consequence, stated so nobody rediscovers it as a bug.** An agreement
document created outside the pack that carries no engagement metadata *and* is
not referenced from the engagement record is **invisible to the pack**.
`agreement_status` reports "not found", which is honest and wrong. Two supported
ways to fix it, both explicit: record the document reference in `engagement.md`,
or declare the value the document actually carries through
`engagement_layout.dedupe_keys.agreements`. The firm-specific worker found such a
document and this pack does not; that is a real, accepted narrowing, not an
oversight.

## Slot 4 — `portal` — operation-shaped, never repo-shaped

The draft contract had `build` and `deploy`. That is a repo talking. A firm whose
client-facing surface is a SaaS project tool plus a shared drive cannot implement
either, and it is the more common shape of the two.

The portal slot is therefore defined by what the firm wants the client to see, and
the transport is entirely the binding's problem. A firm-owned static site
implements `publish_update` by writing content, building, and deploying; a project
tool implements it by creating a task or a status post. Both satisfy the contract;
only the first satisfied the draft.

| Operation | Signature | Required of a binding |
|---|---|---|
| `publish_update` | `(engagement, update{title, body, links}) -> update_ref` | yes. `update` is client-safe prose. Firm-internal commercial state never crosses this call. |
| `share_artifact` | `(engagement, artifact_ref, {label, kind, visibility}) -> share_ref` | yes. **`artifact_ref` is a reference, never bytes.** |
| `portal_status` | `(engagement) -> {surface_label, surface_reachable, last_published_at}` | **DEFERRED — no pack skill implements it.** Narrowed by D2; read the section below before implementing it. |
| `revoke_share` | `(share_ref) -> void` | **optional capability.** Matters at offboarding and handover; absent means the operator does it by hand. |

**Empty behaviour.** Updates are written to the engagement folder as dated notes
and the firm delivers them however it already does. Nothing is published.

### `portal_status` — narrowed and marked deferred (D2)

The credentialed parity run found `portal_status` **declared in this contract and
implemented by nothing**, with a return shape that could not be populated
honestly. A declared-but-fictional operation in a frozen contract is worse than a
missing one: it invites an implementation that returns a comforting value which
means nothing. So this section states both halves plainly.

**Deferred.** No pack skill implements `portal_status` in v1, and the pack ships
no portal skill at all. The operation stays in the contract because the
*question* is real — an operator needs to know which surface a client sees, and
when it last changed — but it is marked unimplemented rather than left looking
available.

**Narrowed.** The old shape promised `reachable` as an **engagement-level** fact.
It is not obtainable for a portal behind authentication: a real engagement slug,
and a slug invented purely for the test that corresponds to nothing, returned the
same authenticated application shell with the same title. The transport layer
carries no engagement-level signal at all, so a `reachable: true` derived from a
response code asserts something the evidence cannot support. `last_published_at`
had no source whatsoever. The field is therefore renamed and re-scoped:

| Field | Rule |
|---|---|
| `surface_label` | Local. Comes from the binding's `mapping.defaults.surface_label`. Always answerable. |
| `surface_reachable` | A **surface-level** claim — "is the client-facing surface up" — never "does this engagement have a page on it". Tri-state `true \| false \| unknown`, and it **must be `unknown`** unless the binding can make a **content-level** assertion that distinguishes a real engagement from a fabricated one. A transport-level response code is never sufficient on an authenticated surface. |
| `last_published_at` | **Undeclared** unless the binding has a real source for it. The pack's own publish events are recorded in the engagement record; that is the honest local source. Never synthesize one. |

An implementation that returns `surface_reachable: true` from a bare `200` is a
bug, not a fast path. The same caution applies in spirit to `transcripts_status`'s
`reachable`, which was **not** re-scoped here because no evidence was gathered
about it — that is an untested surface, not a cleared one.

### Where work product lives — resolved, not deferred

**Decision: the portal contract absorbs work product via `share_artifact`. There
is no `deliverables` slot in v1.**

The second-firm walk flagged that neither `portal` nor `agreements` obviously
covered "where the deliverable lives" — a design tool for one firm, a generated
design pack for the other. Both are the same shape once you stop looking at the
storage and look at the operation: *a reference to a thing the firm made, made
visible to the client.* `share_artifact` is that operation, and a sixth slot would
have been a second binding to the same tool for both validation firms.

What that decision explicitly buys, and explicitly does not:

- **In scope.** Recording that an artifact exists, what it is, where it lives, and
  making it visible on the client-facing surface. `artifact_ref` is a URI or a
  vault path plus a `kind` label; `visibility` distinguishes client-visible from
  firm-internal.
- **Out of scope for v1, stated so nobody assumes otherwise.** The pack does not
  store work product, does not upload or copy files, does not render or thumbnail
  them, does not version them, and runs no approval workflow over them. Asset
  storage stays in whatever tool made the asset.
- **The honest gap.** A firm whose deliverables never become client-visible
  through any surface — handed over live on a call, say — gets nothing from this
  slot. `engagement.md` records the link by hand. That is a v1 limitation, not a
  hidden feature.

## Slot 5 — `transcripts`

| Operation | Signature | Required of a binding |
|---|---|---|
| `list_calls` | `(engagement, since) -> [call_ref]` | yes for tool bindings; **unsupported for pointer bindings**, which say so |
| `fetch_transcript` | `(call_ref) -> {text \| location, occurred_at, participants}` | yes. A pointer binding returns the pointer location — the document *is* the answer. |
| `transcripts_status` | `(engagement) -> {reachable, last_seen_at, source_label}` | yes |

**Pointer bindings are first-class here.** One validation firm has automated
capture; the other's call record is a document a human keeps. Requiring a capture
service would have made the pack uninstallable for the second. A pointer to a
document is a complete, supported answer to the transcripts slot.

**Empty behaviour.** Call notes are whatever the operator pastes into the
engagement folder. No source is polled.

## Recommendations — the only place a vendor name is allowed

An **empty** slot may carry a hint:

```yaml
crm:
  binding: null
  recommended:
    tool: attio          # a suggestion, nothing more
    reason: <why, in one line>
    required: false      # may never be true; absent resolves to false
```

Rules the validator enforces:

- A `recommended:` block is only meaningful on an empty slot. On a bound slot it
  is contradictory and rejected — the firm already chose.
- `required: true` is rejected. A recommendation that can become mandatory is a
  default vendor wearing a disguise.
- Skills surface a recommendation **once**, as an option, and record the decline
  so they stop asking.
- Declining every recommendation leaves a fully functional install.

Every vendor name anywhere in this pack's contract layer is the value of a
`recommended.tool` key in an example config, or this paragraph explaining that
fact. No code path branches on any of them, no slot requires any of them, and
removing every recommendation would change nothing about how the pack runs.

## Known gaps at the contract layer

Written down so they stay decisions rather than becoming rediscoveries.

### Cross-source flags have no home here (D4)

A firm-specific status board can join all four external slots at once and raise
flags on the *combination* — no agreement while the engagement is active, an
invoice drafted but never sent, an invoice past due, an active engagement with no
invoice at all. **No slot and no pack skill reproduces that**, and none is
planned for v1.

The **decision** (owner's, recorded here rather than left implicit): those flags
are a **reporting view over the slots, not an adapter contract**. Every one of
them encodes a particular firm's commercial judgement about when a combination of
states deserves an alert, and the pack has no honest way to decide that for a
firm it has never met. Generalising them would mean shipping one firm's alerting
policy as everybody's default — exactly the kind of hidden assumption the rest of
this document exists to remove.

The **consequence**, which is the part that matters: adopting this pack does
**not** reproduce a firm's existing cross-source alerting. A firm-specific
aggregator that computes these flags must keep running, as a firm-scoped skill,
after the rest of the lifecycle has moved onto the slots. Retiring it because
"the pack has parity on the slots" would switch working alerting off silently.
Slot parity is not board parity, and the retirement gate has to name both.

### Others

- **`portal_status` is deferred**, not available — see the portal slot above.
- **`agreement_status` will not fuzzy-match a client name**, so a document with
  neither a recorded reference nor a join value is invisible — see the agreements
  slot above.
- **Cross-tenant trackers.** `engagement_layout` can express a path into another
  company's tree; a firm-bound session correctly cannot read through it. The
  isolation boundary is deliberate.

## What a lifecycle skill may assume

1. `engagement.md` exists and is the truth. Every other surface is derived.
2. A slot may be `bound`, `empty`, or `undeclared`, and all three must be handled.
   A skill that only handles `bound` is broken.
3. External writes — sends, publishes, signature requests, live billing — are
   gated on explicit human approval, every time.
4. An adapter failure degrades to the empty behaviour plus a clear report. It
   never fabricates data and never silently changes engagement state.
5. Secrets are referenced by vault name and resolved through the HQ secret
   workflow. A skill that reads a credential out of the config is a bug.
6. The join key is resolved **per slot**, from `engagement_layout`, and never
   re-derived by hand or reused across slots. A key that resolves to
   **unresolved** (declared-none) blocks the write for that slot and is reported;
   it is never replaced with a fallback value, because a write on a join value
   the slot cannot match creates a duplicate rather than failing.
