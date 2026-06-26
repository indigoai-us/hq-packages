---
name: client-action-items
description: Track a person's action items with mutable status, ingested from a company's signals store. Use when the user wants to process or work through their action items, check or update the action-item tracker, mark an item done or dismissed, or ingest new action items from signals. The read-only "what are my action items" query belongs to client-signals — this skill owns the mutable tracker. Company-agnostic: resolves company + owner from companies/{co}/client-management.yaml.
allowed-tools: Bash, Read, Write, Edit, Grep, AskUserQuestion
---

# Client action items

A **mutable tracker** for action items assigned to a company's owner, ingested
from that company's signals store.

Action items originate as `action_item` signals (see `client-signals`). Those
signal files are immutable, content-addressed extraction records with **no
status**. This skill maintains a separate mutable tracker that references each
signal and carries a status through to completion.

## Resolve context first

Read `companies/{co}/client-management.yaml` for the **`owner`** (whose items to
track) and confirm the signals store `companies/{co}/signals/` exists. The
tracker lives at `companies/{co}/action-items/`.

## The two core pieces (generic)

1. **Ingest** — copy `action_item` signals owned by the config owner into the
   tracker as `incomplete` items. Idempotent: dedupe on `signal_id`, so it's
   safe to run repeatedly. This is the seam a post-sync hook or scheduled task
   can drive later.
2. **Tracker** — one Markdown file per item under
   `companies/{co}/action-items/<id>.md`, carrying a `status` through a defined
   lifecycle. One file per item keeps cross-machine sync conflicts minimal.

> **Processing/dispatch is pluggable, not built in.** Indigo drives an
> autonomous per-item worker (cmux + headless Claude). That dispatch layer is
> environment-specific and is **not** part of this generic skill — wire it as a
> company extension if you want it. This skill owns ingest + the tracker + manual
> status transitions, which are universal.

## Tracker store

`companies/{co}/action-items/<id>.md` — `<id>` is the first 8 characters of the
source `signal_id`. HQ-tracked and autosaved.

```yaml
---
id: <signal_id[:8]>          # short, human-referenceable id
signal_id: <full sha256>     # source signal — dedupe key
status: incomplete
owner: "<owner name from config>"
owner_inferred: false        # true when ownership came from canonical_content
title: "<short title>"
priority: "<High|Medium|Low, or empty>"
source_meeting: "<meeting-id>"
artifacts: []                # paths to drafts / research produced
created_at: <iso8601 Z>
updated_at: <iso8601 Z>
---
# <title>

<canonical_content from the signal>

## Source                    # written by ingest — meeting + verbatim citation
- **Meeting** `<meeting-id>` — transcript: `sources/meetings/<meeting-id>.md`
- **Cited** (<timestamp>): "<verbatim transcript quote>"

## Progress log
- <iso> ingested from signal <signal_id>
```

## Status lifecycle

| Status | Meaning |
|--------|---------|
| `incomplete` | Ingested, not yet worked. |
| `in-progress` | Being worked. |
| `awaiting-review` | An artifact (draft, research) is ready for the user. |
| `awaiting-approval` | An action with an external side effect is prepared and needs go-ahead. |
| `needs-input` | Blocking questions; see the item's `## Next steps`. |
| `completed` | Done. |
| `blocked` | A hard blocker. |
| `dismissed` | The user decided not to do it. |

## Commands — `/client-action-items [mode]`

### `ingest`

Pull new `action_item` signals owned by the config owner into the tracker as
`incomplete` items. Dedupe on `signal_id` (idempotent). Use the same ownership
logic as `client-signals` (Owner line, or leading-actor inference flagged
`owner_inferred: true`). Preview with a dry run before writing.

### `list [status]`

Show the tracker grouped by status (or filtered to one status).

### `update <id> <status>`

Manual status change with a note, e.g. mark an item `dismissed` or `completed`.
Set `updated_at` and append a `## Progress log` line — don't hand-write the
progress log out of band.

### `process` (default)

1. Run `ingest` to pull any new signals.
2. `list incomplete` and show the items.
3. If a dispatch extension is wired for this company, confirm the set with the
   user (`AskUserQuestion`) and hand off. Otherwise, present the incomplete items
   for the user to work manually and `update` as they go.

## Autonomy boundary (if a dispatch extension is wired)

Any per-item worker must stay within **local and reversible work only**: write
files, draft, research, make local code changes. It must NOT take external
side-effect actions — send email/Slack, deploy, grant access, push a branch,
open a PR, or spend money. If an item needs such an action, prepare it fully and
set `awaiting-approval`; never perform it autonomously.

## Related skills

- **`client-signals`** — reads the raw signals store (read-only). This skill
  consumes its `action_item` output and adds mutable status.
- **`/crm`** — pipeline/account status. A different domain; unrelated to this
  personal task tracker.
