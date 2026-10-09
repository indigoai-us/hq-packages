---
id: client-service-materialize-not-mount
title: Firm capability reaches a client company by materialization, never by a runtime mount
when: client-service || client-pack || firm-pack || cross-company || capability || handover
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
scope: pack:hq-pack-client-service
tags: [client-service, isolation, provenance, packs]
public: true
version: 1
created: 2026-08-05
source: pack:hq-pack-client-service
---

## Rule

When a firm's capability — its skills, knowledge, templates, or workers — must be
available inside a client company, deliver it by **copy-with-provenance
materialization into that client company**.

NEVER create a runtime cross-company mount, an extended read grant, a symlink
into the firm's tree, or a dual-bound session in order to make one company's
content live-readable from another.

Concretely, for this pack:

1. **Two sessions, never one.** The firm assembles a bundle in a session bound to
   the firm. A separate session bound to the **client** installs it. No single
   session is ever bound to both, and no operation reads across the boundary.
2. **The bundle is the only transport.** It is staged in company-neutral
   workspace territory. A client-bound operation reads the bundle and the client
   tree — never `companies/{firm}/`.
3. **`sourceFirm` is provenance, not a path.** It records where content came from
   so it can be updated or revoked. It is never dereferenced to reach the firm's
   tree. Revocation must therefore keep working after the firm is gone.
4. **Materialized files carry their origin and version** — `.hq-pack-manifest.json`
   with a per-file digest — so an update rewrites only what is still
   pack-owned, and a client's own edits are detected and preserved.
5. **A session whose binding cannot be resolved is refused.** Unknown is not
   authorization.

## Rationale

Runtime mounts violate HQ's one-company-per-session and one-bucket-per-STS
isolation model. They also make local and cloud behaviour diverge, and they tend
to pull firm knowledge or secrets into a client session that has no need for
either — a category-1 isolation failure, not a convenience trade.

Provenance-tagged materialization preserves the experience the firm wants (its
craft is present in the client's HQ) while keeping a single-company
authorization boundary. It is also the strictly safer failure mode: a mount that
breaks exposes the wrong tree, whereas a materialization that breaks merely
leaves a stale copy that the manifest can reconcile.

This rule is why the client-pack flow looks like two commands instead of one.
That shape is deliberate, and routing around it — by re-binding a session
mid-flow, or by reading the firm's path from `sourceFirm` — reintroduces exactly
the risk the split exists to remove.

## Related

- `core/knowledge/public/client-service/adapter-contracts.md`
- `client-service-internal-external-split`
- `client-service-approval-gate-external-actions`
