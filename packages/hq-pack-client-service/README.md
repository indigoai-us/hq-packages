# hq-pack-client-service

Turn any HQ company into a **client-service firm** — an agency, a consultancy, a
studio, a fractional practice.

The pack ships the engagement lifecycle as a generic worker, the dual-home client
model as skills, and firm packs as a copy-with-provenance mechanism. It is
**tool-agnostic**: every external integration is an *adapter slot* the firm binds
to its own tooling in its own config file. Nothing vendor-specific is compiled
into the pack.

**v0.1.0.** Everything documented below is landed and verified — see
[CHANGELOG.md](CHANGELOG.md) for what shipped and what is still unproven.

Requires **hq-core >= 15.0.0**.

---

## Quickstart

Four steps: install → onboard the firm → first client → first firm pack.

### 1. Install

Local path — this is the verified distribution path for v0.1.0:

```bash
hq packages install /abs/path/to/core/packages/hq-pack-client-service
```

`hq packages install` accepts a bare slug (registry), `@scope/name[@ver]`, a git
URL, or a local path. For a local path it copies the pack into
`core/packages/` and runs `core/scripts/scan-packages.sh` to wire the
contributions into host-side well-known paths. Expected output:

```
-> transport: local; source: .../core/packages/hq-pack-client-service
  [scan-packages] wiring hq-pack-client-service
  linked .../core/workers/public/client-services -> .../workers/client-services
  linked .../.claude/skills/onboard-firm    -> .../skills/onboard-firm
  linked .../.claude/skills/new-client      -> .../skills/new-client
  linked .../.claude/skills/client-pack     -> .../skills/client-pack
  linked .../.claude/skills/handover-client -> .../skills/handover-client
  linked .../core/knowledge/public/client-service -> .../knowledge/client-service
  linked .../core/policies/client-service-*.md    -> .../policies/client-service-*.md

OK Installed hq-pack-client-service@0.1.0 -> core/packages/hq-pack-client-service/
  Wired 10 contribution(s) into host-side paths.
Run `/onboard-firm` to get started
```

Confirm the wiring:

```bash
hq packages list        # -> contributes {workers:1, skills:4, knowledge:1, policies:4}
                        #    links {live:10, broken:0, missing:0, foreign:0}
```

> On a pre-release host (`hqVersion: 15.0.77-beta.4`, say) `hq packages list`
> reports `hqCoreSatisfied: false` against `>=15.0.0`. That is standard semver
> prerelease exclusion, not a real incompatibility, and it does not block install.

If the pack tree is already in place and you only need to re-wire it:

```bash
bash core/scripts/scan-packages.sh
```

> **Install from the gated `@indigoai-us` registry:**
> `hq packages install hq-pack-client-service --company <firm>` resolves the bare
> slug through the Cognito/entitlement-gated registry — the same posture as
> `hq-pack-parker`. The local-path install above still works for development. The
> manifest's `access: public` is the npm-style install-scope axis, not the
> marketplace gate.

### 2. Onboard the firm — once

In a session bound to **the firm's** company:

```
/onboard-firm
```

The skill asks about what detection could not settle, then drives the
deterministic engine. To run it unattended, or to see what it would do:

```bash
# what does this firm already have?
bash core/packages/hq-pack-client-service/scripts/detect-tools.sh --company {firm}

# plan only — writes nothing
bash core/packages/hq-pack-client-service/scripts/onboard-firm.sh \
  --company {firm} --dry-run

# apply, with every decision explicit
bash core/packages/hq-pack-client-service/scripts/onboard-firm.sh \
  --company {firm} \
  --bind crm=<tool>:<mcp|cli|api>[:<VAULT_SECRET_NAME>] \
  --empty billing \
  --skip portal
```

| Flag | Effect |
|---|---|
| `--bind <slot>=<tool>:<connector>[:<SECRET_NAME>]` | bind the slot |
| `--empty <slot>` | write `binding: null` — a decision |
| `--skip <slot>` | leave undeclared — unknown, asked again next run |
| `--no-auto` | decide nothing that was not passed explicitly |
| `--non-interactive` | auto-resolve everything unspecified (the default) |
| `--dry-run` | print the plan, write nothing |

This writes `companies/{firm}/client-service.yaml` and scaffolds `clients/` plus
`clients/_templates/engagement.template.md` — **the firm's own** engagement
template, which the firm then edits. Re-running with the same inputs makes zero
edits and leaves the config byte-identical.

Check it any time:

```bash
bash core/packages/hq-pack-client-service/scripts/validate-config.sh \
  companies/{firm}/client-service.yaml            # add --strict for CI

bash core/packages/hq-pack-client-service/workers/client-services/scripts/slot-state.sh \
  --firm {firm} --slot all
```

### 3. First client

An HQ session may be bound to exactly **one** company. This flow spans two — the
firm and the client — so it runs in **two phases, in two sessions**. See
[Two phases, two sessions](#two-phases-two-sessions) below.

**Phase 1, in a FIRM-bound session:**

```
/new-client
```

or directly:

```bash
bash core/packages/hq-pack-client-service/scripts/new-client.sh engagement \
  --firm {firm} --client {slug} --client-name "{Display Name}" --local-only
```

Writes `companies/{firm}/clients/{slug}/engagement.md` from the firm's own
template, one pending adapter entry per **bound** slot, and a company-neutral
handoff record under `workspace/`. A slug collision aborts and writes nothing.
Add `--dry-run` to plan it first.

**Phase 2, in a CLIENT-bound session.** Preferred: run `/newcompany {slug}` first
so the client company gets the proper discovery interview, brand packs and
integrations, then verify rather than duplicate:

```bash
bash core/packages/hq-pack-client-service/scripts/new-client.sh client-home \
  --client {slug} --company-scaffold require --invites declined
```

Without `/newcompany`, the default `--company-scaffold auto` writes the minimal
equivalent company tree itself. Either way phase 2 stages
`companies/{client}/handover-checklist.md` and is fully idempotent.

For a cloud-backed client, run `/designate-team {slug}` in this same
client-bound session — that is what flips `company.yaml` to `cloud: true` and
provisions the vault. The engine never runs it; it prints it.

**Invites are gated.** Omitting `--invites` is UNDECIDED, not approval. Even on
`--invites approved` the engine **sends nothing** — it stages the exact commands
at `workspace/client-service/new-client/{client}-invites.txt` for a human, or for
`/new-hire`, to run.

Check status at any point:

```bash
bash core/packages/hq-pack-client-service/scripts/new-client.sh status \
  --firm {firm} [--client {slug}]
```

### 4. First firm pack

**Scaffold, in a FIRM-bound session:**

```bash
bash core/packages/hq-pack-client-service/scripts/client-pack.sh scaffold \
  --firm {firm} --pack {pack} --version 1.0.0 \
  --include skills/{some-skill} --include knowledge/{some-file}.md
```

Creates `companies/{firm}/packs/{pack}/` (content paths mirror company scope 1:1)
and stages a portable bundle at `workspace/pack-staging/{firm}/{pack}/`. That
bundle is the only thing the client side ever reads from the firm. After editing
the pack, restage with `--stage-only`.

**Apply / update / remove, in a CLIENT-bound session:**

```bash
P=core/packages/hq-pack-client-service
bash $P/scripts/client-pack.sh apply  --client {client} --firm {firm} --pack {pack}
bash $P/scripts/client-pack.sh update --client {client} --pack {pack}
bash $P/scripts/client-pack.sh remove --client {client} --pack {pack}
bash $P/scripts/client-pack.sh status --client {client} --pack {pack}   # read-only
```

`apply` writes
`companies/{client}/.hq-packs/{pack}/.hq-pack-manifest.json` recording
`sourceFirm`, `packName`, `version`, per-file `sha256`, `appliedAt` and
`grantedVia`. `update` rewrites only unforked manifest-owned files; `remove`
deletes only unforked manifest-owned files. **Client edits are detected as forks
and always survive.** Add `--dry-run` to any verb to see the plan.

`client-pack.sh` has no `--help`; run it with no verb to print usage.

### Running the lifecycle

```
/run client-services                      # list the worker's skills
/run client-services new-engagement
/run client-services engagement-kickoff
/run client-services track-project
/run client-services deal-pipeline
/run client-services invoicing
/run client-services build-agreement
```

### Ending an engagement

```
/handover-client
```

or directly, in a CLIENT-bound session:

```bash
P=core/packages/hq-pack-client-service
bash $P/scripts/handover-client.sh verify \
  --client {client} --firm-domain {firm-domain} --firm-member {email}

bash $P/scripts/handover-client.sh transfer \
  --client {client} --to {client-principal-email} \
  --initiator-role remove --approval approved
```

`verify` changes nothing and exits 0 whatever the verdict (add `--strict` to make
`BLOCKED` exit 1 for CI). `transfer` re-runs the full verification first, refuses
on `BLOCKED`, prints the approval gate, and only then nominates the new owner —
then reads the roster back to prove the firm's access actually landed where the
checklist says. See [Handover](#handover) for what is and is not proven.

---

## What it contributes

10 contributions, all wired by `scan-packages.sh`:

| Kind | Name | Lands in |
|---|---|---|
| Worker | `client-services` | `core/workers/public/client-services` |
| Skill | `onboard-firm` | `.claude/skills/onboard-firm` |
| Skill | `new-client` | `.claude/skills/new-client` |
| Skill | `client-pack` | `.claude/skills/client-pack` |
| Skill | `handover-client` | `.claude/skills/handover-client` |
| Knowledge | `client-service` | `core/knowledge/public/client-service` |
| Policy ×4 | `client-service-*` | `core/policies/client-service-*.md` |

The pack ships **no hooks**, contributes **no commands**, and installs nothing
into `core/scripts/`.

- **`client-services` worker** — the de-vendored engagement lifecycle:
  `new-engagement`, `engagement-kickoff`, `track-project`, `deal-pipeline`,
  `invoicing`, `build-agreement`. Every integration call goes through an adapter
  operation. `portal-sync` and `call-monitor` are deliberately deferred out of
  v1 for contract-level reasons written out in full under `deferred_adapters` in
  `workers/client-services/worker.yaml`.
- **Pack policies** (`enforcement: hard`, `scope: pack:hq-pack-client-service`)
  ship inside the pack and are excluded from the `hq-core` release set per
  `hq-pack-policies-excluded-from-core-release`. A host that has not installed
  this pack inherits none of them.

---

## Two phases, two sessions

This is not a style choice. HQ's scope authorizer binds a session to exactly one
company, and both the client flow and the pack flow span two.

| Flow | Phase | Session bound to | Writes |
|---|---|---|---|
| `/new-client` | `engagement` | the **FIRM** | `companies/{firm}/clients/{slug}/` |
| `/new-client` | `client-home` | the **CLIENT** | `companies/{client}/` |
| `/client-pack` | `scaffold` | the **FIRM** | the firm pack dir + a bundle under `workspace/` |
| `/client-pack` | `apply`/`update`/`remove` | the **CLIENT** | `companies/{client}/` only |
| `/handover-client` | all verbs | the **CLIENT** | `companies/{client}/` only |

`workspace/` is company-neutral, which is what makes the handoff work **with**
the scope gate rather than around it. The firm reaches phase 2 only as a **name**
— `sourceFirm` in the manifest, the firm slug in the handoff record. It is
provenance and a revoke key, never a path, and no client-side verb ever
dereferences it.

Each engine enforces the binding itself and refuses when it cannot determine
one — unknown is not authorization:

```
ERROR  E_SESSION_SCOPE  this session is bound to 'northgate-partners' but the
       operation writes into client company 'atlas-widgets'.
```

Outside a session (CI, fixtures) state it explicitly with `--session-company`.

---

## The firm/client dual-home model

Every client gets **two homes**, and they are deliberately different things.

```
companies/{firm}/                      companies/{client}/
├── client-service.yaml                ├── (client-owned HQ company)
├── clients/                           ├── handover-checklist.md
│   ├── _templates/                    └── .hq-packs/{pack}/
│   │   └── engagement.template.md          └── .hq-pack-manifest.json
│   └── {slug}/
│       └── engagement.md   ← firm-internal source of truth
└── packs/{name}/           ← the firm's own capability bundles
```

**1. Firm-internal home — `companies/{firm}/clients/{slug}/engagement.md`.**
The canonical engagement state: scope, stage, pipeline, billing posture,
internal notes. It lives in the *firm's* vault. Everything else — portal pages,
decks, status rollups, CRM records — is a derived view of this file. The firm
keeps this home forever; it is the firm's own record.

**2. Client-facing home — `companies/{client}/`.**
A separate, fully isolated HQ company. This is the isolation boundary *and* the
handover boundary: it is the thing the client can eventually own outright. The
firm's craft reaches it only by **materialization, not mounting** — `/client-pack
apply` copies files in and records a `.hq-pack-manifest.json`, so a client
session never reads the firm vault (policy
`client-service-materialize-not-mount`, shipped with this pack). Revocation stays
surgical: `remove` deletes only unforked, manifest-owned files, and anything the
client edited or created survives.

The internal/external split never leaks in either direction.

The client-facing company is **optional**. A firm can run local-only, with no
cloud identity, and still get both file trees; cloud steps are skipped with the
reason named, which is a first-class outcome and not a failure.

---

## Bring your own tools

Five adapter slots, defined by the operations the lifecycle skills call — never
by a product name:

| Slot | Operations |
|---|---|
| `crm` | `resolve_dedupe_key`, `upsert_company`, `upsert_deal` (+ optional `mirror_stage`, `read_back`) |
| `billing` | `ensure_customer`, `draft_invoice`, `send_invoice`, `billing_status` (+ optional `void_invoice`, `ensure_recurring_billing`) |
| `agreements` | `render_agreement`, `request_signature`, `agreement_status` (+ optional `store_executed`) |
| `portal` | `publish_update`, `share_artifact`, `portal_status` (**deferred — unimplemented in v1**) (+ optional `revoke_share`) |
| `transcripts` | `list_calls`, `fetch_transcript`, `transcripts_status` |

A firm binds each slot in its own `client-service.yaml` as
`{tool_name, connector (mcp|cli|api), mapping, secret_name}`. A slot may also
take a `pointer` binding (`kind` + `location`) when the answer is a *place* — a
document a human maintains — rather than a tool.

### Three slot states, never two

| State | Written as | Means |
|---|---|---|
| `bound` | `binding:` mapping, or `pointer:` | the firm runs something here |
| `empty` | **`binding: null`, written explicitly** | the firm decided it runs nothing here |
| `undeclared` | slot key absent | nobody has answered yet — unknown |

**`empty` is never inferred from absence, and `undeclared` is never reported as
`empty`.** A firm that has no CRM writes `binding: null` and means it; a config
that predates the question stays undeclared and gets asked.

### Empty slots degrade, they do not fail

An install where **all five slots are empty is fully supported**. Every lifecycle
skill resolves the slot first and then takes a documented local path: it names
the slot, names the state, says what it did instead, makes **zero external
writes**, and invents no data. `invoicing` with no billing slot drafts a plain
invoice into the engagement folder and stops. `deal-pipeline` with no CRM answers
pipeline questions from the engagement records. An unbound slot is never an
error.

An empty slot may carry an optional `recommended:` hint that skills surface
**once**, clearly marked optional. `recommended.required` is written `false` and
the validator rejects `true`. Declining is a supported permanent end state.

### `engagement_layout` — where the record actually lives

Added during the first-install dogfood, when the first real firm broke the v1
assumption that every firm keeps one engagement path and one tracker glob. The
whole block is optional; absent resolves byte-for-byte to the v1 defaults.

```yaml
engagement_layout:
  engagement_path: 'companies/{firm}/engagements/{slug}/record.md'
  tracker_sources:
    - 'companies/{firm}/work/{slug}-*/prd.json'
  dedupe_key: '{slug}'
  overrides:
    some-engagement:
      dedupe_key: 'legacy-alias'      # the join key predates the slug
```

- `tracker_sources` is a **list** — a firm may keep trackers in more than one
  tree. `tracker_sources: []` written explicitly is **declared-none** ("we track
  this somewhere you cannot read") and does **not** fall back to the default
  glob. Absent is undeclared and does.
- `dedupe_key` defaults to `{slug}` but may be an alias, which keeps the key
  local and pure while making the local computation correct.
- Resolver: `workers/client-services/scripts/engagement-layout.sh` (read-only).
  `track-project` and `deal-pipeline` call it instead of assembling paths.
- `secret_name: null` written explicitly is likewise **declared-none** — a
  binding onto a host-native surface with no vault secret behind it. Absent still
  means undeclared.

### `dedupe_keys` — one join value per (engagement, **slot**)

Added by the credentialed parity run. `mapping.dedupe_field` was always declared
per slot, but the value that went into it was resolved per engagement — so the
pack assumed one key was valid in every slot's join field. A firm whose ledger
joins on a short alias and whose CRM joins on a registrable domain has no single
string that is both. The read symptom is a rejected lookup; the **write**
consequence is worse, because every write here is search-then-create and a search
on a value the field cannot hold falls through to **create a duplicate**.

```yaml
engagement_layout:
  dedupe_key: '{slug}'               # the general key
  dedupe_keys:
    crm: null                        # declared-none: no firm-wide value here
  overrides:
    some-engagement:
      dedupe_key: 'legacy-alias'     # ledger + agreements join on the alias
      dedupe_keys:
        crm: 'example.com'           # ...the CRM does not
```

Precedence, most specific first — **scope first, then slot within a scope**:

| # | Declared at | `source` |
|---|---|---|
| 1 | `overrides.<slug>.dedupe_keys.<slot>` | `override-slot` |
| 2 | `overrides.<slug>.dedupe_key` | `override` |
| 3 | `dedupe_keys.<slot>` | `firm-slot` |
| 4 | `dedupe_key` | `firm` |
| 5 | `{slug}` | `default` |

A config with no `dedupe_keys` anywhere reaches only 2, 4 and 5 — the three
levels that existed before — so it resolves exactly as it always did, for every
slot. `dedupe_keys.<slot>: null` written explicitly is **declared-none**: the key
is *unresolved*, the write is blocked and reported, and it never falls back to a
value the slot cannot join on. Resolve it with
`engagement-layout.sh --firm {firm} --engagement {slug} --slot {slot}`.

Because level 2 outranks level 3, a per-engagement general key shadows a
firm-level per-slot key; that is the layout block's existing rule, and the
validator warns about the combination by name
(`W_LAYOUT_DEDUPE_KEY_SHADOWS_SLOT`) so it cannot happen by accident.

---

## Handover

`/new-client` stages `companies/{client}/handover-checklist.md` as the runway.
`/handover-client` flies it: it verifies every item, refuses to move while
anything is unverified, and only then nominates the client's principal as owner
through the hq-pro ownership-transfer flow.

Three rules it exists to enforce:

1. **Unknown is never done.** Every item resolves to `DONE`, `INCOMPLETE` or
   `UNKNOWN`, and the last two block identically. No roster is not an empty
   roster; a membership with no `status` is not "active"; an unfilled secret
   table is not "there were no secrets".
2. **The gate is the only door.** `--approval approved` is required, and the
   skill passes it only after an explicit in-session human yes. `declined` and
   *absent* both change nothing.
3. **Read it back.** After the nomination the engine re-reads the roster and
   compares it against the end state the checklist declares. An exit code is not
   evidence about a membership graph.

The transfer **nominates**; ownership moves only when the nominee accepts in
their own session. A real handover is therefore usually two sittings.

A local-only company gets a clear "ownership transfer requires a cloud-backed
company" notice and exit 0, not a failure. An *undeclared* `cloud:` key resolves
to local, because unknown never authorizes a cloud action.

> **Not yet proven.** The cloud leg of `/handover-client` has never run against a
> real stack. Every piece of its evidence is against a **mocked transfer surface**
> behind `--hq-bin`, and the hq-pro routes it calls are not deployed. Treat the
> transfer path as unproven until that smoke runs. `verify`, `status` and the
> local-only path are fully covered by fixtures.

---

## Security posture

- **Zero secret values in this pack.** Config and examples reference secrets by
  **vault name only**. `/onboard-firm` reads secret *names* and never calls
  `hq secrets get`, `--reveal`, `exec`, `env` or `hq run`. A credential value in
  `client-service.yaml` is a named validation error
  (`E_INLINE_CREDENTIAL_KEY`), not a style problem.
- **Approval gates** on client invites, external sends, publishes, signature
  requests, deploys and live billing. One approval covers one action; a standing
  approval from earlier in the session does not count.
- **The firm vault is never read from a client session.** Capability is
  materialized into the client company, not mounted across the boundary.
- **Live billing is signed-only and test-first** — a signed agreement on file,
  the same flow already proved in test mode, a mode guard, and per-action
  approval.
- No engine in this pack makes a network call. Cloud steps are *printed* for a
  human, never executed, and every harness proves it with a PATH shim layer over
  `curl`/`wget`/`hq`/`gh`/`aws`/`ssh`/`scp`/`nc`/`open`.

---

## Verify your install

All five harnesses are fixture-only, run under `$TMPDIR`, never touch a real
company tree, and re-run their guard scenarios against deliberately broken copies
of the engine — a test that cannot fail is itself treated as a failure.

```bash
P=core/packages/hq-pack-client-service

bash $P/scripts/validate-config.sh $P/examples/firm-a.yaml     # PASS
bash $P/scripts/validate-config.sh $P/examples/firm-b.yaml     # PASS
bash $P/scripts/validate-config.sh $P/examples/broken.yaml     # FAIL, 4 named errors, exit 1

bash $P/workers/client-services/tests/run-e2e.sh               # 21 assertions
bash $P/scripts/client-pack-verify.sh                          # ALL GREEN
bash $P/scripts/new-client-verify.sh                           # ALL GREEN
bash $P/scripts/handover-client-verify.sh                      # ALL GREEN
bash $P/scripts/e2e-smoke.sh                                   # 103 assertions, whole arc
```

To prove the smoke can actually go red:

```bash
bash $P/scripts/e2e-smoke.sh --list-faults
bash $P/scripts/e2e-smoke.sh --seed-fault fork-detect          # -> exit 1
```

The fault is patched into the *fixture* copy only; the run checksums the real
pack tree before and after and fails if a single byte moved.

---

## Layout

```
package.yaml                     manifest (contributes, requires, gating)
README.md                        this file
CHANGELOG.md                     what shipped, and what is unproven
skills/{onboard-firm,new-client,client-pack,handover-client}/SKILL.md
workers/client-services/         worker.yaml + runbook.md + 6 skills + scripts/ + tests/
knowledge/client-service/        adapter-contracts.md + client-service.schema.yaml
scripts/                         the engines + validate-config.sh + the verify harnesses
policies/                        the four lifecycle hard rules
examples/                        firm-a / firm-b / broken configs
templates/                       handover-checklist.md
```

The engagement template is deliberately **not** a pack file: `/onboard-firm`
writes it to `companies/{firm}/clients/_templates/engagement.template.md` so the
firm owns and edits its own copy, and `/new-client` instantiates **that** file,
never a pack-side one.
