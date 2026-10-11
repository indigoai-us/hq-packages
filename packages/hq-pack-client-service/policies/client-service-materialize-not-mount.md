---
id: client-service-materialize-not-mount
title: Firm capability reaches a client company by materialization, and a firm session reaches a client only through an explicit session lock
when: client-service || client-pack || firm-pack || cross-company || capability || handover || multi-company || (add && company)
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
scope: pack:hq-pack-client-service
tags: [client-service, isolation, provenance, packs, multi-company]
public: true
version: 2
created: 2026-08-05
updated: 2026-10-09
source: pack:hq-pack-client-service
---

## Rule

### Access: explicit, per session, and visible

A firm session may work in a client company only when that client is in the
session's company lock set. Add it explicitly:

```bash
bash core/scripts/hq-session.sh add company {client}
```

The firm stays the primary company. Add only the clients the task needs, and
remove each one (`hq-session.sh remove company {client}`) when the task is done.
Every company not in the lock set stays blocked.

On an hq-core without multi-company session locks, the lock set is a single
company and the original two-session flow applies: firm phases in a firm-bound
session, client phases in a client-bound session.

NEVER widen access any other way: no symlink into another company's tree, no
extended read grant, no copied credential, no editing a scope-capability file by
hand.

### Content: materialized, never mounted

When the firm's capability (its skills, knowledge, templates or workers) must be
available inside a client company, deliver it by **copy-with-provenance
materialization** with `/client-pack`. A multi-company session does not change
this.

1. **The bundle is the only transport.** It is staged in company-neutral
   workspace territory. A client-side operation reads the bundle and the client
   tree, never `companies/{firm}/`, even when the firm is in the same session.
2. **`sourceFirm` is provenance, not a path.** It records where content came from
   so it can be updated or revoked. It is never dereferenced to reach the firm's
   tree. Revocation keeps working after the firm is gone.
3. **Materialized files carry their origin and version** in
   `.hq-pack-manifest.json`, with a per-file digest, so an update rewrites only
   what is still pack-owned and a client's own edits are preserved.
4. **Firm-internal content never lands in a client company.** Engagement notes,
   commercials and internal coordination stay in `companies/{firm}/` (policy
   `client-service-internal-external-split`). Holding both companies in one
   session makes a copy easy; it does not make it allowed.
5. **A session whose lock set cannot be read is refused.** Unknown is not
   authorization.

## Rationale

The lock set gives an agency the convenience it needs (one session for the firm
and the client it is serving) while keeping access explicit and auditable: a
company is reachable only after a named `add company`, and nothing else is.

Materialization still governs content. A client company can be handed over at
any time, so it must never depend on, or contain, the firm's private tree. A
mount that breaks exposes the wrong tree; a materialization that breaks leaves a
stale copy the manifest can reconcile.

## Related

- `core/knowledge/public/client-service/adapter-contracts.md`
- `client-service-internal-external-split`
- `client-service-approval-gate-external-actions`
