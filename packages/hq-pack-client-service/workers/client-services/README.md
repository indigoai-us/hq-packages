# workers/client-services

**status: landed (US-004).**

The generic, de-vendored client-service lifecycle worker. `worker.yaml`
(`worker.id: client-services`) and `runbook.md` live here, with six skills:

`new-engagement`, `engagement-kickoff`, `track-project`, `deal-pipeline`,
`invoicing`, `build-agreement`.

`scan-packages.sh` links this directory to `core/workers/public/client-services`,
and `core/scripts/generate-workers-registry.sh` indexes the `worker.yaml` from
there.

## Layout

| Path | What it is |
|---|---|
| `worker.yaml` | worker definition, adapter-slot index, `deferred_adapters`, `verification` |
| `runbook.md` | the operating procedure the skills follow |
| `skills/*.md` | the six lifecycle skills |
| `scripts/slot-state.sh` | read-only tri-state slot resolver — every skill's step 0 |
| `tests/` | the US-004 E2E: two fixtures plus `run-e2e.sh` |

## Contract this worker honours

- Every integration reference goes through an adapter operation frozen in
  US-002. No vendor names, ids, company slugs or URLs from any specific firm.
- The hard rules ship as pack policies in `../../policies/`: `engagement.md` is
  the source of truth; the internal/external split never leaks; an approval gate
  guards every publish, external send and live billing write; billing is
  signed-only and test-first.
- `portal-sync` and `call-monitor` are deliberately **absent** from v1. Both
  reasons are contract-level, not effort-level, and are written out in full under
  `deferred_adapters` in `worker.yaml`.
- Three slot states, always distinguished. A slot that is `empty` or
  `undeclared` produces a named report and **zero writes** — never an error,
  never invented data.
- `verification` defines `engagement_grounded`, `approval_gate_passed` and
  `slot_degradation_clean`, each with an explicit `fails_when`.

## Running the E2E

```bash
bash tests/run-e2e.sh
```

Validates both fixtures against the frozen schema, runs `deal-pipeline`'s step 0
against a config where only the billing slot is bound, asserts the crm slot is
reported as not configured (and that `empty` and `undeclared` stay distinct), and
proves no writes by checksumming the worker tree plus a scratch firm workspace
before and after.
