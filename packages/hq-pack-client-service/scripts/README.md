# scripts/

**status: landed.** Nothing is declared in `contributes.scripts`, so nothing
here is linked into the host's `core/scripts/` — these are pack-local tools
invoked by path, which is deliberate rather than pending.

Contents:

- `validate-config.sh` (US-002) — validates a firm's `client-service.yaml`
  against `knowledge/client-service/client-service.schema.yaml`. Must pass
  `examples/firm-a.yaml` and `examples/firm-b.yaml` and fail `examples/broken.yaml`
  with a named error.
- `detect-tools.sh` (US-003) — proposes adapter-slot candidates from the
  company's `settings/`, its configured MCP servers, and vault secret **names**.
  Reports each source's status separately, because "not scanned" and "scanned,
  found nothing" are different answers. Never resolves a secret value.
- `onboard-firm.sh` (US-003) — the non-interactive engine behind the
  `/onboard-firm` skill: detect, resolve each slot, write
  `companies/{firm}/client-service.yaml`, scaffold `clients/` and
  `clients/_templates/engagement.template.md`, then validate its own output.
  Never prompts (the skill asks and passes explicit `--bind`/`--empty` flags),
  never rewrites a slot that is already bound or already empty, and writes
  nothing timestamped so a re-run leaves the file byte-identical.
- `new-client.sh` (US-005) — the non-interactive engine behind the `/new-client`
  skill, split into two phases because a session may be bound to only one company:
  `engagement` (FIRM-bound) writes `clients/{slug}/engagement.md` from the firm's
  template plus a pending adapter entry per **bound** slot; `client-home`
  (CLIENT-bound) scaffolds the client company and stages
  `handover-checklist.md`. A slug collision aborts and changes nothing. Invites
  are emitted only on an explicit `--invites approved`. It makes **no external
  call of any kind** — cloud steps are printed for a human, never run.
- `new-client-verify.sh` (US-005) — fixture-only regression suite for the above,
  including the PRD E2E (local-only + invites declined) with a PATH shim proving
  no external call was made, and discrimination checks that re-run the collision
  and invite-gate scenarios against deliberately broken copies which must fail.
- `client-pack.sh` (US-006) — delivers a firm's packs into a client company by
  copy-with-provenance: `scaffold` (FIRM-bound) stages a portable bundle into
  `workspace/`, and `apply`/`update`/`remove`/`status` (CLIENT-bound) read only
  that bundle plus the client tree, so no verb ever reads the firm while writing
  the client. `apply` records a sha256 per copied file, which is what lets
  `update` and `remove` recognise a client edit as a **fork** and preserve it
  byte-for-byte instead of overwriting it. Reporting a fork is a success, not an
  error.
- `client-pack-verify.sh` (US-006) — fixture-only regression suite for the
  above, covering manifest/byte agreement, no-op re-apply, fork survival across
  both update and remove, and absent-field safety (a manifest entry with no
  sha256 is preserved, not treated as clean). Its fork scenarios are re-run
  against a deliberately broken copy whose fork detection always answers
  "clean" and must fail there — a fork test that passes with fork detection off
  proves nothing.
- `e2e-smoke.sh` (US-007) — offline fixture smoke over the whole loop
  (install → onboard-firm → new-client → client-pack scaffold/apply/fork/update/remove).
  Accumulates a real failure count, exits non-zero on any failure, and cleans up
  fixtures even when it fails. `--seed-fault <name>` (see `--list-faults`) patches
  a deliberate regression into the *fixture* copy of `client-pack.sh` — never the
  real one — so the smoke can be demonstrated going red; a seeded run that still
  passes is itself reported as a failure.

  Its offline proof is a PATH shim dir, and the `hq` shim is **selective**, for a
  durable platform reason rather than a local workaround. `core/scripts/scan-packages.sh`
  is no longer self-contained bash: it is a **forwarder** that exec's
  `hq core --hq-root <root> scan-packages`, because the pack-contribution mapping
  is now single-sourced in the CLI (`src/utils/pack-contributions.ts`). So `hq` is
  two different things at once, and the shim splits them:

  - `hq core …` — local host operations (symlinking a pack's contributions into an
    HQ root). Delegated to a resolved real CLI and recorded in a separate local-call
    log. Never a violation.
  - every other subcommand — `secrets`, `sync`, `dm`, `invite`, `publish`, `deploy`,
    `files`, `login`, `whoami`, `run`, … — logged to the violation log and exited 97.
    Those are what the offline proof exists to catch.

  Step 1 asserts both directions at the same checkpoint: the local call demonstrably
  happened, and it demonstrably was not written to the violation log. `curl`, `wget`,
  `gh`, `aws`, `ssh`, `scp`, `nc` and `open` stay shimmed totally.

  The real CLI is resolved once at start-up from the pristine PATH and baked into the
  shim by absolute path, so delegation can never re-enter the shim by name. The probe
  is for the **capability**, not liveness — it reads `core --help` and requires
  `scan-packages` to be listed, because a dangling npm symlink is `command -v`-visible
  while broken, and an older CLI answers `--version` happily and then dies on `core`
  with `unknown command`. Order: `hq` on PATH, then `node <HQ root>/repos/private/hq-cli/dist/index.js`,
  overridable with `HQ_SMOKE_CLI`. If nothing qualifies the harness exits **2** with a
  named environment error rather than silently skipping the install step. Note that
  `hq core scan-packages --help` is *not* a help path — it wires packs into whatever
  root it is pointed at, so never probe with it.
- `handover-client.sh` (US-011) — the deterministic engine behind the
  `/handover-client` skill: `verify`, `transfer`, `verify-access`, `status`.
  Every checklist item resolves to DONE / INCOMPLETE / UNKNOWN and **both of the
  last two block** — a checked box whose cross-check cannot be run is a claim,
  not evidence, and handover is irreversible from the firm's side. The ownership
  transfer fires only on an explicit `--approval approved`; declined and absent
  both do nothing at all, and absent is reported as undecided rather than read
  as consent. Exactly one outward seam exists (`--hq-bin`, for the roster read
  and the transfer write), and firm access is re-derived from a fresh roster
  read afterwards, because "exited 0" is not evidence.
- `handover-client-verify.sh` (US-011) — fixture-only regression suite for the
  above, with two independent mechanical safety nets: PATH shims that record and
  fail every external binary, and a mocked `--hq-bin` that replays canned
  responses while recording exact argv. Covers the blocking states, undeclared
  firm identity, the approval gate proved by checksum to change nothing when
  declined or undecided, the approved US-010 transfer, and the post-transfer
  read-back.
