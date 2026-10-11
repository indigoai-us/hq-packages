---
name: new-client
description: Create both homes for a new client engagement. Writes the firm-internal home companies/{firm}/clients/{slug}/engagement.md from the firm's own template, and optionally creates the isolated client-facing HQ company (via /newcompany, with --cloud driving /designate-team). A slug collision aborts. Client-team invites sit behind an explicit approval gate; declining completes everything else. Adapter entries are written only for bound slots. Stages handover-checklist.md in the client company as the runway for /handover-client. Works fully local-only when there is no cloud identity.
triggers:
  - new client
  - start a client engagement
  - onboard a new client
  - create client company
  - set up a client engagement home
maturity: HQ-native (authored for this package)
---

# /new-client — the dual-home flow

Every client gets **two homes**, and they are not the same kind of thing.

| | Firm-internal home | Client-facing home |
|---|---|---|
| Where | `companies/{firm}/clients/{slug}/` | `companies/{client}/` — a separate HQ company |
| Owns | the engagement truth: stage, commercials, contacts, decisions, internal coordination | the client's own work; it is the isolation boundary **and** the handover boundary |
| Who sees it | the firm | the client (eventually — this company is what gets handed over) |

Nothing firm-internal is ever written into the client company. That is not a
convention here, it is the reason the second home exists (policy
`client-service-internal-external-split`).

Engine: `../../scripts/new-client.sh`. Fixture suite:
`../../scripts/new-client-verify.sh`.

## The operating requirement, first: two phases, one or two sessions

This flow spans two companies, the firm and the client, so it runs in two
phases. Each phase writes into exactly one company, and the session must hold
that company in its lock set:

| Phase | Session must hold | Reads | Writes |
|---|---|---|---|
| `engagement` | the **FIRM** | `companies/{firm}/` | `companies/{firm}/clients/{slug}/` |
| `client-home` | the **CLIENT** | a company-neutral handoff record under `workspace/` | `companies/{client}/` |

**One session (hq-core with multi-company session locks).** Run `engagement` in
the firm's session. Create the client company if needed, then add it to the same
session and run `client-home`:

```bash
bash core/scripts/hq-session.sh add company {client}
```

The firm stays the primary company. Remove the client from the session when you
are done with it (`hq-session.sh remove company {client}`).

**Two sessions (older hq-core, or by preference).** Run `engagement` in a
firm-bound session and `client-home` in a session bound to the client.

Either way, the handoff record
(`workspace/client-service/new-client/{firm}--{client}.yaml`) carries the firm's
slug and display name as **provenance**: a name, an audit fact. Phase 2 never
dereferences it as a path and never opens the firm tree, even when the firm is in
the same session (policy `client-service-materialize-not-mount`).

The engine reads the session's lock set (`hq-session.sh get company_slugs`) and
refuses when the target company is not in it, or when it cannot read it:

```
ERROR  E_SESSION_SCOPE  this session is locked to 'northgate-partners' but this
       phase writes into client company 'atlas-widgets'.
```

Outside a session (CI, fixtures) state it explicitly with `--session-company`,
which takes one slug or a comma-separated lock set (`firm,client`).

## Step 1 — Settle the inputs before writing anything

Ask, one question per `AskUserQuestion` call:

1. **Client slug** — lowercase, hyphens. It names both the engagement folder and
   (usually) the client company, so it is worth a moment. A slug starting with
   `_` is refused: leading-underscore names are reserved for pseudo-directories
   such as `clients/_templates/`.
2. **Display name** — free text, e.g. "Acme Manufacturing Ltd".
3. **Does this client get their own HQ company?** Default yes. A client with no
   company still gets the firm-internal home; say so plainly rather than
   pretending the flow failed.
4. **Cloud or local-only?** See "Local-only mode" below. Do not ask if there is
   obviously no cloud identity — say which you detected and why.
5. **Client-team invites** — collect intended addresses, but *do not treat
   collecting them as approval*. The gate is step 4.

Dry-run first if anything is uncertain:

```bash
bash core/packages/hq-pack-client-service/scripts/new-client.sh engagement \
  --firm {firm} --client {slug} --client-name "{Name}" --dry-run
```

## Step 2 — Phase 1: the firm-internal home (FIRM-bound session)

```bash
bash core/packages/hq-pack-client-service/scripts/new-client.sh engagement \
  --firm {firm} --client {slug} --client-name "{Name}" [--cloud|--local-only]
```

It does exactly four things:

1. Instantiates **the firm's own** `clients/_templates/engagement.template.md` at
   `clients/{slug}/engagement.md`, filling `{{CLIENT_NAME}}`, `{{FIRM_NAME}}`,
   `{{CLIENT_SLUG}}`, `{{FIRM_SLUG}}`, `{{TODAY}}`. If the firm has no template
   the run stops (`E_NO_ENGAGEMENT_TEMPLATE`) and points at `/onboard-firm`. It
   never substitutes a pack-side template for the firm's.
2. Writes one **pending adapter entry per bound slot** (see below).
3. Writes the company-neutral handoff record for phase 2.
4. Reports the other engagements in `clients/`, excluding leading-underscore
   pseudo-dirs.

### Slug collision aborts. Always.

If `clients/{slug}` already exists — directory, file or symlink — the run exits
non-zero with `E_SLUG_COLLISION` and **writes nothing at all**. An existing
engagement is a human's file and a human's history; `/new-client` never
overwrites, merges into, or resets one. Resolve it by continuing in the existing
record, or by choosing a distinct slug. Do not "clean up" the old folder to make
the command succeed.

This is also why re-running phase 1 for an existing client is not idempotent-
by-no-op but idempotent-by-refusal: the second run changes nothing and says why.

### Adapter entries — bound slots only

Slot state comes from the one resolver,
`../../workers/client-services/scripts/slot-state.sh`, and only `crm` and
`portal` have anything to record at creation time (billing, agreements and
transcripts have nothing to say until there is an agreement or a call).

| Slot state | What is written |
|---|---|
| `bound` | `clients/{slug}/adapters/{slot}.md` — a **pending** local record: the dedupe key and the contract operations a human will approve later |
| `empty` | **nothing.** Not a file, not a placeholder. The firm decided it runs no tool here |
| `undeclared` | **nothing**, and the report says *unknown, not empty*, and points at `/onboard-firm` |

If neither slot is bound, no `adapters/` directory is created at all. Nothing in
this phase calls a CRM or a portal — the entries describe work that is still
gated.

## Step 3 — The client company (session that holds the CLIENT)

Either add the client to the firm's session
(`bash core/scripts/hq-session.sh add company {slug}`, once the company exists)
or switch to a session bound to the client. See "The operating requirement"
above.

Preferred path: run **`/newcompany {slug}`** — it does the discovery interview,
brand packs and integrations properly. Then run phase 2 with
`--company-scaffold require` so it verifies rather than duplicates:

```bash
bash core/packages/hq-pack-client-service/scripts/new-client.sh client-home \
  --client {slug} --company-scaffold require --invites declined
```

If `/newcompany` is not being run (unattended, or the operator declines the
interview), phase 2's default `--company-scaffold auto` writes the minimal
equivalent itself: `company.yaml` with `cloud: false`, `board.json`, `settings/`,
`data/`, `knowledge/`, `skills/`, `workers/`, `policies/`, `projects/`,
`people/`, `workspace/`, and a `companies/manifest.yaml` entry. `/newcompany` can
still be run later; it is additive over that tree.

With `--cloud`, run **`/designate-team {slug}`** in this same session, while it
holds the client. The engine never runs it — it prints it. `/designate-team` is what flips
`company.yaml` to `cloud: true` and provisions the vault.

Phase 2 also stages `handover-checklist.md` (below) and is fully idempotent: a
second run with the same inputs reports zero changes and leaves the tree
byte-identical. An existing checklist is never overwritten.

## Step 4 — The invite gate

**Inviting a person is an outward-facing action.** It is gated, and the gate is
real:

- Ask with `AskUserQuestion`, showing **every address**, the company they are
  being invited to, and the role. Approval on a summary is not approval
  (policy `client-service-approval-gate-external-actions`).
- Only after an explicit yes, pass `--invites approved --invite <email>[:<role>]`.
- **Declining is a complete, supported outcome.** `--invites declined` skips
  invites and finishes everything else — company, checklist, cloud note. The
  checklist records the decline so the next person knows it was a decision.
- **Omitting `--invites` is not approval.** It is UNDECIDED: nothing is emitted
  and the report says so. Absent never means yes.

Even on approval the engine **sends nothing**. It stages the exact commands at
`workspace/client-service/new-client/{client}-invites.txt` for a human to run (or
for `/new-hire` to drive). Approval authorizes the send; it does not delegate it
to a script.

## Step 5 — The handover checklist

`companies/{client}/handover-checklist.md`, from
`../../templates/handover-checklist.md`. It is the **executable runway** for
`/handover-client` (US-011), not a formality: client team owns the company, firm
packs in their intended end state, secrets rotated or removed, ACLs and shares
revoked, client-facing surfaces transferred, commercials closed, knowledge
continuity, sign-off. Every item has a checkbox, most have the command that
verifies them, and unknown never counts as done.

It lives in the client's company, so it is client-visible: it carries no
firm-internal state, and neither may anything you add to it.

## Local-only mode

Local-only is a **first-class outcome, not a failure**. Both file trees are
produced in full; only cloud steps are skipped, with the reason stated.

Detection, when neither `--cloud` nor `--local-only` is passed:

| Signal | Resolution |
|---|---|
| no `hq` CLI on PATH | local-only — there is no cloud identity to act with |
| `company.yaml` declares `cloud: true` | cloud steps offered |
| `company.yaml` declares `cloud: false` | local-only |
| `company.yaml` has **no** `cloud` key | local-only — undeclared is *unknown*, and unknown never authorizes a cloud action. Pass `--cloud` to override |

Detection is filesystem-only. The engine never executes `hq`, never
authenticates, and never reaches the network — `command -v hq` is the whole of
it. What is skipped is named explicitly: `/designate-team`, cloud provisioning
and invite delivery, none of which failed — they were not attempted.

## What this skill never does

- **No external call, in any mode.** No invite sent, no CRM written, no portal
  published, no vault touched, no network. Everything outward-facing is emitted
  as a plan for a human.
- **No overwrite of an existing engagement, checklist, or client company.**
- **No firm-internal content in the client company.**
- **No secret value** anywhere — names only, and only where a name is already
  recorded in the firm's config.
- **No `_`-prefixed directory** listed as, auto-selected as, or accepted as a
  client. One general leading-underscore rule, never a special case for
  `_templates`.

## Verification

```bash
bash core/packages/hq-pack-client-service/scripts/new-client-verify.sh
```

Fixture-only — invented companies under `$TMPDIR`, never a real tree. It asserts
the PRD end-to-end case (local-only, invites declined → both trees exist and the
external-call log is empty, proved by PATH shims over `curl`/`hq`/`gh`/`aws`/…),
collision abort with a byte-identical tree, bound-only adapter writes, idempotent
re-runs, underscore safety, both directions of the session-scope refusal, and the
invite gate across declined / undecided / approved.

It then re-runs the collision and invite-gate scenarios against copies of the
engine with those guards removed, and **fails if those runs still pass**. A guard
test that cannot fail proves nothing.

## Depends on

- `../onboard-firm/SKILL.md` — must run first; it writes the firm's engagement template.
- `../../workers/client-services/scripts/slot-state.sh` — the one tri-state slot resolver.
- `../../templates/handover-checklist.md` — the staged runway.
- `../../knowledge/client-service/adapter-contracts.md` — the slot contracts (frozen).
- `/newcompany`, `/designate-team`, `/new-hire` — driven by the skill, never by the engine.
