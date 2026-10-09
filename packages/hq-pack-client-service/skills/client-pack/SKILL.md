---
name: client-pack
description: Bundle a firm's own skills and knowledge into a firm pack and move it into client HQ companies by copy-with-provenance. Verbs — scaffold, apply, update, remove. Apply writes .hq-pack-manifest.json recording sourceFirm, packName, version, per-file sha256, and appliedAt; update rewrites only unforked manifest-owned files; remove deletes only unforked manifest-owned files. Client edits are detected as forks and always survive. All writes happen in a session bound to the CLIENT company.
triggers:
  - client pack
  - create a firm pack
  - apply my pack to a client
  - update a firm pack in a client hq
  - remove a firm pack from a client
---

# /client-pack — firm capability, materialized with provenance

A firm's craft travels into a client HQ by **copy-with-provenance**. Nothing is
mounted, nothing is read across a company boundary at runtime, and the client's
own edits are never overwritten or deleted.

Implementation: `../../scripts/client-pack.sh`.
Fixture regression suite: `../../scripts/client-pack-verify.sh`.

## The operating requirement, first

**Two sessions, never one.**

| Phase | Session must be bound to | Reads | Writes |
|---|---|---|---|
| `scaffold` (author + stage) | the **FIRM** | `companies/{firm}/packs/{name}/` | the firm pack dir, and a portable bundle in `workspace/pack-staging/{firm}/{name}/` |
| `apply` / `update` / `remove` | the **CLIENT** | the staged bundle in `workspace/` + the client tree | `companies/{client}/` only |

`workspace/` is company-neutral, which is why this works **with** the
`mandatory-scope-authorizer` gate rather than around it: no verb ever needs a
session that can see two companies at once. The manifest's `sourceFirm` is
provenance metadata — a name, an audit fact, a revoke key. It is **never** used
as a path to read at client runtime, and the tool never dereferences it.

The script enforces the binding itself. If it cannot determine which company the
session is bound to, it **refuses to write** — unknown is not authorization.
Outside a session (CI, fixtures) state the binding explicitly with
`--session-company <slug>`.

```
ERROR  E_SESSION_SCOPE  this session is bound to 'northgate-partners' but the
       operation writes into client company 'atlas-widgets'.
```

This is policy `client-service-materialize-not-mount` (shipped with this pack) made
mechanical. HQ has already rejected live company→company access as a category-1
isolation risk; copy-with-provenance is the sanctioned substitute, and this skill
is its local implementation. A cloud delivery backend can replace the copy loop
later without changing the record it writes.

## Verbs

### `scaffold` — author the pack, in a FIRM-bound session

```bash
client-pack.sh scaffold --firm northgate-partners --pack service-kit \
  [--version 1.0.0] [--include skills/status-report] [--include knowledge/house-style.md]
client-pack.sh scaffold --firm northgate-partners --pack service-kit --stage-only   # restage after edits
```

Creates `companies/{firm}/packs/{name}/` with `pack.yaml` plus `skills/`,
`knowledge/`, `workers/`, `policies/`. **Content paths mirror company scope 1:1** —
`packs/{name}/skills/x/SKILL.md` lands at `companies/{client}/skills/x/SKILL.md`,
so the materialized capability is a real client skill, not a parked copy.
`--include <type>/<name>` seeds the pack from the firm's own assets.

Every scaffold run also **stages a portable bundle** at
`workspace/pack-staging/{firm}/{pack}/` (`pack.json` + `content/`). That bundle is
the only thing the client-side verbs ever read from the firm. Re-run with
`--stage-only` after editing the pack.

Symlinks inside a pack are refused (`E_BUNDLE_SYMLINK`): a symlink can resolve
back into the firm vault at client runtime, which is exactly the mount this
mechanism exists to avoid.

### `apply` — install into a client, in a CLIENT-bound session

```bash
client-pack.sh apply --client atlas-widgets --firm northgate-partners --pack service-kit
```

Copies bundle content into the client company and writes
`companies/{client}/.hq-packs/{pack}/.hq-pack-manifest.json`.

- A target path that already exists but is **not** manifest-owned is a client
  file: it is kept, never overwritten, and never adopted into the manifest
  (`collision-kept`).
- **Re-apply of the same version is a no-op.** An *absent* `version` in the
  existing manifest is unknown, not "the same version", so it falls through to the
  fork-safe reconcile instead of short-circuiting. `--force` reconciles anyway.

### `update` — rewrite only what is still ours

```bash
client-pack.sh update --client atlas-widgets --pack service-kit
```

Per manifest-owned file:

| Client-side state | Action | Report |
|---|---|---|
| sha matches the recorded sha | rewritten from the bundle | `updated` / `unchanged` |
| sha differs — **client edited it** | **skipped, file untouched** | `FORK-skipped` |
| recorded sha absent / null / malformed | **skipped, file untouched** | `FORK-skipped(unknown-sha)` |
| file deleted by the client | not resurrected | `client-deleted-kept` |
| no longer in the pack | left in place, dropped from the manifest | `retired-left-in-place` |

Update refuses outright when there is no manifest (`E_NO_MANIFEST`) — missing
ownership information is unknown ownership, never "nothing is owned".

### `remove` — delete only what is still ours

```bash
client-pack.sh remove --client atlas-widgets --pack service-kit
```

Deletes manifest-owned files whose sha still matches. **Forks, unknown-sha
entries, and client-created files are always kept.** Empty directories left
behind are pruned; directories with any surviving content are not.

If nothing was retained the manifest is deleted. If forks were retained the
manifest is rewritten with `removedAt` and only the retained entries, so a later
re-apply still knows those bytes are the client's.

`remove` never reads the bundle. Revocation works even if the firm is gone.

### `status` — read-only diagnostic

```bash
client-pack.sh status --client atlas-widgets --pack service-kit
```

Prints the classification of every manifest-owned file and changes nothing.
`--dry-run` gives the same view for a specific apply/update/remove plan.

## Fork preservation — the one rule that makes this safe

A **fork** is a manifest-owned file whose current sha256 differs from the sha
recorded at apply time. Forks are detected, skipped, reported, and kept.

The rule that makes it durable: **a fork's manifest entry keeps its ORIGINAL
applied sha forever.** The client's current sha is never adopted. Adopting it
would make the file look clean on the next pass — and a "clean" file is one that
`update` overwrites and `remove` deletes. One line of convenience there is the
difference between safe and catastrophic, which is why `client-pack-verify.sh`
asserts it directly.

Fork detection is **content-based**. A permission or timestamp change is not a
fork; only bytes count.

## The provenance manifest

`companies/{client}/.hq-packs/{packName}/.hq-pack-manifest.json` — the file name is
exactly `.hq-pack-manifest.json`, namespaced one directory per pack so several
firm packs can coexist in one client company without collision.

```json
{
  "schema": "hq-pack-manifest",
  "schemaVersion": 1,
  "sourceFirm": "northgate-partners",
  "packName": "service-kit",
  "version": "1.0.0",
  "appliedAt": "2026-08-05T20:45:35Z",
  "files": [
    { "path": "skills/status-report/SKILL.md", "sha256": "25a1549c…", "appliedVersion": "1.0.0" },
    { "path": "skills/status-report/checklist.md", "sha256": "ed897832…", "appliedVersion": "1.0.0",
      "forked": true, "forkedDetectedAt": "2026-08-05T20:45:36Z" }
  ],
  "grantedVia": {
    "kind": "local-copy",
    "bundle": "workspace/pack-staging/northgate-partners/service-kit",
    "stagedAt": "2026-08-05T20:45:35Z"
  }
}
```

| Field | Meaning |
|---|---|
| `sourceFirm` | who authored the capability. Provenance and revoke key. Never a path. |
| `packName` | which pack. Also the `.hq-packs/` namespace. |
| `version` | the pack version these bytes came from. Drives idempotency. |
| `files[].path` | client-company-relative. `..`, absolute paths and `.hq-packs/` are rejected. |
| `files[].sha256` | the sha **at apply time**, not the current sha. The fork signal. |
| `appliedAt` | when this record was written. |

Advisory, never load-bearing: `files[].appliedVersion`, `files[].forked`,
`files[].forkReason`, `files[].retainedOnRemove`, `removedAt`. A reader must not
infer anything from their absence — the sha comparison is the only authority.

### Forward-compatible with the portfolio entitlement record

The brainstorm's preferred approach shapes this local copy loop as a preview of
the cloud Agency Capability Library, so the library can slot in as a *delivery
backend* without migrating firm content. `grantedVia` is the seam.

- **Today** every record carries `grantedVia: {kind: "local-copy", bundle, stagedAt}`.
- **Later** a reconciler-installed record carries the portfolio PRD's shape —
  `grantedVia: {kind: "subscription", subscriptionId, publishedVersion, …}` — with
  the other five fields unchanged. Same file, same key, no manifest migration, and
  the same fork semantics apply to cloud-materialized files.
- Firm-scoped subscriptions and locally applied packs can therefore coexist in one
  client company, distinguishable by `grantedVia.kind` alone.

**An absent `grantedVia` means unknown provenance path — never "local-copy".**
Records written before this key existed must not be misread as locally copied,
and no verb may branch destructively on its absence.

## Absent is unknown, everywhere

Policy `hq-absent-field-never-means-constraining-value`, applied to the fields
that can destroy client data:

| Absent thing | What it does **not** mean | Actual behaviour |
|---|---|---|
| `files[].sha256` | "unchanged" / "safe to delete" | treated as a fork: skipped by update, kept by remove |
| `sha256: null` or malformed | same | same |
| the whole manifest | "nothing is pack-owned" | update and remove **refuse** (`E_NO_MANIFEST`) |
| manifest `version` | "same version, no-op" | falls through to a fork-safe reconcile |
| bundle `version` | "0" / "latest" | refused (`E_BUNDLE_VERSION_MISSING`) |
| the staged bundle | "nothing left to install" | refused (`E_BUNDLE_MISSING`) — never a cue to clean up |
| session company binding | "authorized" | refused (`E_SESSION_UNKNOWN`) |
| `grantedVia` | "local-copy" | unknown delivery path; nothing branches on it |

Every unknown resolves toward preserving client data.

## Auto-selection

When `--pack` is omitted and exactly one pack is applied in the client, it is
auto-selected from the `.hq-packs/` listing. `_`-prefixed pseudo-dirs are excluded
by a general leading-underscore rule, never a named special case
(policy `hq-auto-select-skips-underscore-pseudo-dirs`). Ambiguity is an error, not
a guess.

## Verification

```bash
bash core/packages/hq-pack-client-service/scripts/client-pack-verify.sh
```

Builds fixture firm and client companies under `$TMPDIR` — it never touches a real
company tree — and asserts: manifest sha values match the copied bytes; re-apply is
a no-op; update rewrites an unmodified file; a forked file survives update
byte-identically and is reported; a forked file and a client-created file survive
remove while unforked files are deleted; and a manifest entry with an absent or
null sha is preserved by both update and remove.

It then re-runs the two fork scenarios against a copy of `client-pack.sh` whose
fork detection is patched to always answer "clean" and requires those scenarios to
**fail**. A fork test that still passes with fork detection disabled proves
nothing, so the suite fails if the discrimination check does not discriminate.

## Limits worth knowing

- Fork detection is content-only; mode and timestamp changes are invisible to it.
- A client-deleted pack file is not resurrected by `update`; it stays owned so
  `remove` remains a no-op for it. Re-installing it is a deliberate `apply
  --force` after the entry is cleared.
- Version drift across many clients is an operator loop today — one `update` per
  client. Managed fan-out is the cloud library's job, not this skill's.
- Bundles under `workspace/pack-staging/` are build output. They are safe to
  delete; restage with `scaffold --stage-only`.
