# policies/

**status: landed (US-004).**

The `client-services` worker's hard rules, in enforceable form. Each is declared
in `../package.yaml` under `contributes.policies`; `scan-packages.sh` symlinks
`policies/{id}.md` into `core/policies/{id}.md` at install time.

Per policy `hq-pack-policies-excluded-from-core-release`, these are deliberately
**not** promoted into the `hq-core` release set — a host that has not installed
this pack must not inherit client-service guardrails. They reach a host only
through `hq install` plus `scan-packages.sh`.

| Policy | Rule in one line |
|---|---|
| `client-service-engagement-is-source-of-truth` | `engagement.md` is canonical; CRM, client-facing surface, agreement and billing objects are derived, optional mirrors, and truth flows one way |
| `client-service-internal-external-split` | firm-internal state never crosses a client-facing operation; client copy is assembled from client-visible sections, never redacted from the whole |
| `client-service-approval-gate-external-actions` | every publish, share, signature request, outbound message, live billing write and binding-internal deploy waits for its own explicit approval |
| `client-service-billing-signed-and-test-first` | no live money without a signed agreement, a proved test run, a mode guard, and per-action approval |

All four are `enforcement: hard` and scoped `pack:hq-pack-client-service`.
