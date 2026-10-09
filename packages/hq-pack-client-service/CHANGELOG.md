# Changelog — hq-pack-client-service

All notable changes to this pack. Versions follow the `version:` field in
`package.yaml`.

Entries describe what **shipped and was verified**, not what was planned. Where
something is unproven, this file says so.

---

## 0.2.0 (2026-10-09)

Multi-company sessions. A firm session can now hold the client it is serving,
using hq-core's multi-company session lock, instead of switching sessions.

- `new-client.sh`, `client-pack.sh` and `handover-client.sh` read the session's
  lock set (`hq-session.sh get company_slugs`, falling back to `company_slug`)
  through one shared helper, `scripts/lib/session-lock.sh`. A phase may write into
  a company only if that company is in the lock set. Unknown is still refused.
- `--session-company` accepts a comma-separated lock set (`firm,client`).
- Policy `client-service-materialize-not-mount` v2: access to a client is
  allowed only through an explicit `hq-session.sh add company`; content still
  reaches a client only by materialization; firm-internal content never lands in
  a client company.
- Skills and README updated for "two phases, one or two sessions".
- Older cores: the lock set is one company, so behaviour is unchanged.

Verified: `new-client-verify.sh` (116 checks, 10 new for multi-company sessions,
including a live lock set read from `hq-session.sh`), `client-pack-verify.sh`
(new scenario 6d), `handover-client-verify.sh`, and `e2e-smoke.sh` (107
assertions), all green. The discrimination checks in the verify suites now copy
the shared helper next to the broken engine copy, so they fail only for the
injected break.

---

## 0.1.1

- **Marketplace cover.** Added `cover.jpg` (1024×574) at the pack root so the
  registry listing carries a branded cover, matching the pack-cover convention
  used by `hq-pack-design-engineering` and `hq-pack-email-assistant`. Generated
  on the Indigo house Midjourney style (`--sref 3195498761`); depicts the
  handover — a luminous world passed between two parties. No code or contract
  changes; contributions are identical to 0.1.0.

## Unreleased

### Fixed — `e2e-smoke.sh` install step, after `scan-packages.sh` became a CLI forwarder

**Platform change, recorded here because it is durable and not specific to this
pack.** On 2026-08-06 `core/scripts/scan-packages.sh` stopped being self-contained
bash. It is now a **forwarder**: it checks for `hq` on PATH and exec's
`hq core --hq-root "$HQ_ROOT" scan-packages "$@"`. The pack-contribution mapping
it used to encode is single-sourced in the CLI (`src/utils/pack-contributions.ts`)
so the two copies cannot drift. The ABI is preserved exactly — arguments, streams
and exit status pass through untouched — so every caller that invokes it by path
still works.

What it broke: `e2e-smoke.sh` proves offline-ness by shimming `curl`, `wget`, `hq`,
`gh`, `aws`, `ssh`, `scp`, `nc` and `open` onto PATH as stubs that log and exit 97.
Once `scan-packages.sh` forwarded into `hq`, the harness's own `hq` shim killed
step 1: `scan-packages.sh exits 0 (expected '0', got '97')`, and every downstream
"is wired" assertion failed because nothing had been wired.

The harness's assumption was the wrong thing, not the forwarder. `hq core …` is a
purely **local host operation** — it symlinks pack contributions into an HQ root
and touches nothing off-machine. Shimming `hq` wholesale was correct when
`scan-packages.sh` was self-contained; against a forwarder it proves nothing and
only removes coverage.

- The `hq` shim is now **selective**. `hq core …` is delegated to a resolved real
  CLI and recorded in a separate local-call log; it is never a violation. Every
  other subcommand — `secrets`, `sync`, `dm`, `invite`, `publish`, `deploy`,
  `files`, `login`, `whoami`, `run`, … — is still logged and exited 97. Those are
  the ones the offline proof exists to catch. `curl`/`wget`/`gh`/`aws`/`ssh`/
  `scp`/`nc`/`open` are unchanged and still shimmed totally.
- Step 1 now asserts the discrimination in **both directions at the same
  checkpoint**: the local `hq core scan-packages` call demonstrably happened, and
  it demonstrably was not written to the violation log. Verified by temporarily
  planting an `hq secrets list` call in a fixture step — the harness went red
  (exit 1) with `hq secrets list` in the shim log while the `hq core` calls stayed
  in the local log, and green again once removed.
- The real CLI is resolved once at start-up from the pristine PATH and baked into
  the shim by absolute path, so delegation can never re-enter the shim by name.
  The probe is for the **capability**, not liveness: it reads `core --help` and
  requires `scan-packages` to be listed. Both weaker probes give wrong answers
  here — a dangling npm symlink is `command -v`-visible while completely broken,
  and an older CLI answers `--version` happily and then dies on `core` with
  `unknown command`, failing the install step for a reason unrelated to this pack.
  Order: `hq` on PATH, then `node <HQ root>/repos/private/hq-cli/dist/index.js`,
  overridable with `HQ_SMOKE_CLI`. If nothing qualifies the harness exits **2**
  with a named environment error rather than silently skipping the install step.
- Caution, learned the hard way: `hq core scan-packages --help` is **not** a help
  path. It runs, and wires packs into whatever root it is pointed at. Never probe
  with it.

### Fixed — step 1 was asserting a stale contributed surface

Independent of the above, step 1 had drifted behind the pack: it asserted 3 skills
and 4 policies. It now asserts all **4** skills (`handover-client` was added in
US-011) and all **5** policies (`client-service-materialize-not-mount` was added).
Both gaps were silent — the assertions passed while under-checking.

Clean run is now **107 assertions, exit 0**; `--seed-fault fork-detect` still goes
red at exit 1 (9 failures). `workers/client-services/tests/run-e2e.sh`,
`scripts/client-pack-verify.sh`, `scripts/new-client-verify.sh`,
`scripts/handover-client-verify.sh` and `scripts/validate-config.sh` over
`examples/{firm-a,firm-b,broken}.yaml` are unaffected and green.

---

## 0.1.0 — 2026-08-05

First release. Turns any HQ company into a client-service firm on existing HQ
primitives only: no new auth model, no new tenant type, no runtime cross-company
access.

### Contributed surface

`hq packages install` + `core/scripts/scan-packages.sh` wire **10 contributions**
into host-side paths:

| Kind | Name | Host path |
|---|---|---|
| Worker | `client-services` | `core/workers/public/client-services` |
| Skill | `onboard-firm` | `.claude/skills/onboard-firm` |
| Skill | `new-client` | `.claude/skills/new-client` |
| Skill | `client-pack` | `.claude/skills/client-pack` |
| Skill | `handover-client` | `.claude/skills/handover-client` |
| Knowledge | `client-service` | `core/knowledge/public/client-service` |
| Policy ×4 | `client-service-*` | `core/policies/client-service-*.md` |

`contributes.hooks`, `contributes.commands` and `contributes.scripts` are all
empty — the pack ships no hook and installs nothing into `core/scripts/`.

### Added — adapter contracts and config schema

- `knowledge/client-service/adapter-contracts.md` — the five slots (`crm`,
  `billing`, `agreements`, `portal`, `transcripts`), described **only** by the
  operations the lifecycle calls. Frozen for v1.
- `knowledge/client-service/client-service.schema.yaml` — the machine-readable
  encoding of the same contract. `validate-config.sh` reads its connector enum,
  slot list, field lists, denylists and error catalogue directly, so contract and
  checker cannot drift.
- **Tri-state slot model.** A slot is `bound`, `empty` (`binding: null`, written
  explicitly — a decision) or `undeclared` (key absent — nobody has answered).
  `empty` is never inferred from absence and `undeclared` is never reported as
  `empty`. An empty or undeclared slot **degrades**: a named report, zero
  external writes, no invented data — never a hard error.
- `scripts/validate-config.sh` with a named error catalogue.
- `examples/firm-a.yaml` (all five slots bound), `examples/firm-b.yaml` (three
  slots empty, a SaaS portal, a document `pointer` for transcripts) and
  `examples/broken.yaml` (four planted faults). The contracts were walked
  against **two** real firms' stacks, not one.

### Added — `client-services` worker

Six skills, de-vendored from a lifecycle proven on real paid engagements:
`new-engagement`, `engagement-kickoff`, `track-project`, `deal-pipeline`,
`invoicing`, `build-agreement`.

- `companies/{firm}/clients/{slug}/engagement.md` is the canonical record; CRM,
  portal, agreement and billing surfaces are derived mirrors of it.
- `scripts/slot-state.sh` — the single read-only tri-state resolver every skill
  runs at step 0.
- `verification` block with three post-execute checks — `engagement_grounded`,
  `approval_gate_passed`, `slot_degradation_clean` — each with an explicit
  `fails_when`.
- `deferred_adapters` records why `portal-sync` and `call-monitor` are
  **deliberately absent** from v1. Both reasons are contract-level, not
  effort-level.

### Added — skills

- **`/onboard-firm`** — one-time, idempotent firm binding. Detects candidates
  from company settings, MCP server names and vault secret **names** (never
  values), reports each source's status separately (`unavailable` means *not
  scanned*, which is unknown — never "the firm has no such tool"), then writes
  `companies/{firm}/client-service.yaml` and scaffolds `clients/` plus
  `clients/_templates/engagement.template.md`. Re-running with the same inputs
  leaves the file byte-identical; nothing written carries a timestamp.
- **`/new-client`** — the dual-home flow, in two phases (`engagement`,
  firm-bound; `client-home`, client-bound). Slug collision **aborts and writes
  nothing**. Adapter entries are written for `bound` slots only. Invites are
  staged as commands for a human, never sent, and only on explicit
  `--invites approved`. Stages `handover-checklist.md` in the client company.
  Local-only is a first-class outcome: both file trees are produced in full and
  only cloud steps are skipped, with the reason named.
- **`/client-pack`** — firm packs by copy-with-provenance:
  `scaffold` / `apply` / `update` / `remove` / `status`. `apply` writes
  `companies/{client}/.hq-packs/{pack}/.hq-pack-manifest.json` recording
  `sourceFirm`, `packName`, `version`, per-file `sha256`, `appliedAt` and
  `grantedVia`. A **fork** (manifest-owned file whose sha differs from the sha
  recorded at apply time) is skipped by `update`, kept by `remove`, and keeps its
  ORIGINAL applied sha forever. Symlinks inside a pack are refused
  (`E_BUNDLE_SYMLINK`) — a symlink can resolve back into the firm vault.
- **`/handover-client`** — verifies `handover-checklist.md`, then runs the
  hq-pro ownership transfer behind an explicit approval gate and reads the
  membership roster back. `verify` / `transfer` / `verify-access` / `status`.
  An item it cannot corroborate is `UNKNOWN`, and `UNKNOWN` blocks identically to
  `INCOMPLETE`. `--approval` absent is UNDECIDED, which is not approval.
  `--initiator-role owner` is refused outright.

### Added — policies (pack-scoped, `enforcement: hard`)

`client-service-engagement-is-source-of-truth`,
`client-service-internal-external-split`,
`client-service-approval-gate-external-actions`,
`client-service-billing-signed-and-test-first`.

Per `hq-pack-policies-excluded-from-core-release` these ship **inside the pack**
and are excluded from the `hq-core` release set — a host that has not installed
this pack inherits none of them.

### Added — verification harnesses

Every harness is fixture-only, runs under `$TMPDIR`, proves it made no external
call with a PATH shim layer over `curl`/`wget`/`hq`/`gh`/`aws`/`ssh`/`scp`/
`nc`/`open`, and re-runs its guard scenarios against deliberately broken copies
of the engine so a test that cannot fail is itself a failure.

| Harness | Coverage |
|---|---|
| `scripts/e2e-smoke.sh` | the whole arc — install → onboard → client → pack. 103 assertions, `--seed-fault` to prove it goes red |
| `workers/client-services/tests/run-e2e.sh` | slot tri-state + `engagement_layout` resolution. 21 assertions |
| `scripts/client-pack-verify.sh` | manifest sha fidelity, re-apply no-op, fork survival through update and remove |
| `scripts/new-client-verify.sh` | collision abort, bound-only adapter writes, idempotency, underscore safety, both scope-refusal directions, the invite gate across declined/undecided/approved |
| `scripts/handover-client-verify.sh` | blocking guards, the gate (declining proved byte-identical), read-back with seeded mismatches, the local-only path |

### Changed during the first-install dogfood (US-008)

The first real firm broke two v1 assumptions on day one. Both were fixed by
**declaration, not by a vendor branch**; every change is optional and additive,
and an absent block resolves byte-for-byte to the old behaviour.

- **`engagement_layout`** — a new optional top-level config block with
  `engagement_path`, `tracker_sources` (a **list** of glob templates),
  `dedupe_key`, and per-engagement `overrides`. The v1 draft assumed one fixed
  engagement path and one fixed tracker glob per firm; the first real firm had
  engagements in three different trees, zero trackers under the engagement
  folder, and at least one engagement whose billing/agreement join key was an
  alias rather than its slug. New read-only resolver
  `workers/client-services/scripts/engagement-layout.sh`; `track-project` and
  `deal-pipeline` call it instead of assembling paths.
  `tracker_sources: []` written explicitly is **declared-none**, which is a
  different state from absent and does not fall back to the default glob.
- **`stage_labels`** — a new reserved `mapping` key translating the firm's own
  engagement vocabulary to the labels its CRM expects. Absent means undeclared
  (pass through unchanged); a rejection is a warning, never a rewrite of the
  engagement record to match the tool.
- **`ensure_recurring_billing`** — a new optional, gated billing capability, for
  firms whose retainers are standing charges rather than monthly one-off
  invoices. `invoicing` must not infer recurring billing from the word "monthly".
- **`secret_name: null`** written explicitly is now **declared-none** (a binding
  that reaches a host-native surface with no vault secret behind it). Absent
  still means undeclared. The validator skips the name-pattern check on an
  explicit null, and only on an explicit null.

### Changed after the credentialed parity run (D1–D4)

The first run against live services with credentials found one P1 defect and two
gaps that were accidents rather than decisions. Same rule as before: fixed by
**declaration, not by a vendor branch**; additive and optional; an absent block
resolves byte-for-byte to the old behaviour, which is asserted in the suite and
not only claimed.

- **D1 (P1) — `engagement_layout.dedupe_keys`, a join key per SLOT.**
  `mapping.dedupe_field` was always declared per slot, but the value that went
  into it was resolved per engagement, so the contract silently assumed one key
  was valid in every slot's join field. It is not, for a firm whose ledger and
  agreements tool join on a short alias while its CRM joins on a registrable
  domain. The read-side symptom was a rejected lookup on every CRM call. **The
  write-side consequence was the reason this was P1:** every write here is
  search-then-create, and a search on a join value the field cannot hold cannot
  match the record that already exists, so the write falls through to create and
  produces a **duplicate** — exactly the failure idempotency exists to prevent,
  on the first live run, before anyone notices the read was broken.

  `dedupe_keys` is a map keyed by slot name, legal at the firm level and inside
  any override entry, so it composes with the `overrides` mechanism that already
  existed instead of adding a parallel one. The pack still resolves **exactly
  one** join value per (engagement, slot), still locally and purely, with no tool
  call. Precedence is **scope first, then slot within a scope**:
  `overrides.<slug>.dedupe_keys.<slot>` → `overrides.<slug>.dedupe_key` →
  `dedupe_keys.<slot>` → `dedupe_key` → `{slug}`. A config with no `dedupe_keys`
  anywhere can only reach the last three, so it resolves as it always did.
  `dedupe_keys.<slot>: null` written explicitly is **declared-none** — the key is
  *unresolved*, which blocks the write and is reported, and never falls back to a
  value the slot cannot join on. Because level 2 outranks level 3 a per-engagement
  general key shadows a firm-level per-slot key, which is the layout block's
  existing rule and also the way this defect could come back, so the validator
  names that combination (`W_LAYOUT_DEDUPE_KEY_SHADOWS_SLOT`).
  Resolver gained `--slot <name>|all`; without it the report is byte-identical to
  before. `deal-pipeline`, `invoicing`, `build-agreement`, `new-engagement` and
  the `new-client` pending records now resolve per slot.

- **D2 (P2) — `portal_status` narrowed and marked DEFERRED.** No pack skill
  implemented it, and its `reachable` field could not be populated honestly for a
  portal behind authentication: a real engagement slug and a slug invented for
  the test returned the same authenticated shell, so a `true` derived from a
  response code asserts what the evidence cannot support, and `last_published_at`
  had no source at all. Rather than leave a declared-but-fictional operation in a
  frozen contract, the operation is marked `state: deferred, implemented_by:
  none` and its shape is narrowed to what a binding can actually assert:
  `{surface_label, surface_reachable, last_published_at}`. `surface_reachable` is
  a **surface-level** claim, tri-state, and **must** be `unknown` unless the
  binding can make a content-level assertion distinguishing a real engagement
  from a fabricated one. `last_published_at` is undeclared without a real source.
  `transcripts_status.reachable` was deliberately **not** re-scoped — no evidence
  was gathered about it, and an untested surface is not a cleared one.

- **D3 (P3) — no client-name fallback for agreement lookup, by decision.** The
  firm-specific worker this pack replaces falls back to a substring match on the
  client's name when metadata is absent; the pack has only an explicit reference
  and a join-value match. That difference is now a stated decision instead of an
  omission. A name substring is not a join key and cannot be an idempotency key,
  and a false positive attaches another client's signed agreement — and therefore
  another client's commercial terms — to an engagement, silently and plausibly.
  The named consequence: a document created outside the pack with neither a
  recorded reference nor engagement metadata is **invisible** to the pack, and
  the two supported fixes (record the reference, or declare the value it carries
  via `dedupe_keys.agreements`) are both explicit.

- **D4 — cross-source flags stay firm-specific, recorded rather than closed.**
  A firm-specific status board joins all four external slots and raises flags on
  the combination (no agreement while active, an invoice drafted but never sent,
  an invoice past due, an active engagement with no invoice). **No pack change
  was made**: the owner's decision is that these are a reporting view over the
  slots, not an adapter contract, because each encodes one firm's commercial
  judgement about when a combination deserves an alert. The consequence is now
  written into `adapter-contracts.md` so it is not rediscovered: adopting the
  pack does not reproduce that alerting, so **slot parity is not board parity**
  and a retirement decision has to name both.

- **Regression coverage.** `run-e2e.sh` section `[3c]`, 17 new assertions over
  two new fixtures (`firm-slot-dedupe-keys.yaml`,
  `firm-slot-dedupe-keys-malformed.yaml`): every precedence level including the
  pack default, declared-none at two levels, `{slug}` substitution inside a slot
  key, the shadow warning firing and being silenced, unknown slot names warning
  instead of failing, malformed declarations as named errors, and the
  backward-compatibility guarantee asserted directly — a config with no
  `dedupe_keys` resolves all five slots to its one key, and its default report
  grows no new lines. 14 of the 17 fail with the fix reverted; the 3 that do not
  are compatibility guards that can only fail with the fix *present*.

### Known limitations in 0.1.0

- **Distribution:** published to the gated `@indigoai-us` registry; installable
  by bare slug (`hq packages install hq-pack-client-service`) for entitled
  companies. Local-path install remains supported for development.
- **`/handover-client`'s cloud leg is unproven against a real stack.** All of its
  evidence is against a mocked transfer surface behind `--hq-bin`. The hq-pro
  ownership-transfer routes it calls cannot deploy yet.
- **Adopting the pack does not retire a firm's existing firm-specific worker.**
  The dogfood proved the generic worker can express the same lifecycle through
  slots; it did not cut anything over. On the first install the legacy
  firm-specific worker is still present and byte-identical, and retiring it is a
  separate, explicit decision. The credentialed run added two reasons it must
  stay for now: `portal_status` is deferred (D2), and the cross-source flags have
  no home in the pack by decision (D4), so slot parity is not board parity.
- **`portal_status` is declared but unimplemented.** Deferred on purpose and
  labelled as such everywhere it appears, rather than silently absent.
- **Agreement lookup has no name fallback.** A document with neither a recorded
  reference nor a join value is invisible to the pack. Decided, not missing (D3).
- **Cross-tenant trackers.** An engagement whose delivery work lives in the
  client's own HQ company can have its path expressed by `engagement_layout`, but
  a firm-bound session correctly cannot read through it. The isolation boundary
  is deliberate.
- **Version drift across many clients is an operator loop** — one
  `client-pack update` per client. Managed fan-out is the cloud library's job.
- Fork detection is content-only; a mode or timestamp change is not a fork.
- `client-pack.sh` has no `--help`; run it with no verb to print usage.
- On a pre-release host version (e.g. `hqVersion: 15.0.77-beta.4`),
  `hq packages list` reports `hqCoreSatisfied: false` against
  `requires.hqCore: '>=15.0.0'`. That is standard semver prerelease exclusion,
  not a real incompatibility, and it does not block install.
