---
name: client-signals
description: Surface a person's action items, commitments, decisions, risks, and open questions from a company's signals store — meeting intelligence extracted from that company's meeting notes. Use when the user asks "what are my action items", "what do I need to do", "what's on my plate", "what did I commit to", "check signals", or wants follow-ups, decisions, or risks pulled from recent meetings. Company-agnostic: resolves the company and owner from companies/{co}/client-management.yaml.
allowed-tools: Bash, Read, Grep
---

# Client signals

Read a company's **signals store** to answer questions about a person's action
items, commitments, decisions, risks, and open questions. Signals are structured
meeting intelligence — discrete items extracted from meeting transcripts.

When the user asks what they need to do, what they committed to, or to "check
signals," **check this store** — don't reach for the CRM/pipeline systems first.
(Pipeline work is `/crm` and the CRM-management skills; this is the personal
task/intelligence layer.)

## Resolve context first

1. Determine the company `{co}` (from the request, the active session, or ask).
2. Read `companies/{co}/client-management.yaml` for:
   - **`owner`** — whose "my action items" these are (name + optional
     `person/<slug>` entity ref + email).
   - **`meetings.source`** — which meeting backend feeds signals.
3. The signals store is `companies/{co}/signals/`. If it's absent, the company
   hasn't run signal extraction yet — say so and point at `meeting-next-steps`
   for a live pull instead of inventing items.

## Store layout

Each signal type is a directory; every signal is one content-addressed Markdown
file `<sha256>.md`:

```
companies/{co}/signals/
  action_item/              one file per extracted action item
  commitment/               promises a participant explicitly made
  decision/                 decisions reached in a meeting
  risk/                     risks, blockers, concerns raised
  question/                 open questions with no resolution yet
  key_point/                notable discussion points
  participant_contribution/ what a specific person contributed
  summary/                  per-meeting summaries
  _index/<date>.json        index of signals written on each date
```

### Signal file schema

YAML frontmatter, then a Markdown body:

```yaml
---
canonical_content: <one-sentence normalized statement of the signal>
citations:
  - location: <HH:MM:SS timestamp in the transcript>
    source_ref: sources/meetings/<meeting-id>.md
    text: <verbatim quote>
entity_refs:
  - person/<slug>
  - project/<slug>
  - company/<slug>
source_ref: sources/meetings/<meeting-id>.md
type: action_item
signal_id: <sha256>
---
# Action Item: <title>

**Owner:** <name>
**Priority:** <High|Medium|Low>

<prose description>
```

The **`_index/<date>.json`** files list `{signal_id, type, source_ref, key,
written_at}` for every signal written that date — use them to find what's new
since a given date.

## Answering "what are my action items"

"The user" means the config **`owner`**. Match on the owner's distinctive name
token (e.g. first name), case-insensitively.

1. Scan `action_item/*.md`.
2. An item is the owner's when the body's **`**Owner:**`** line names them —
   match a single distinctive token, because the field can read `Jane Doe`,
   `Jane Doe & Sam Lee`, or `Jane Doe (add to PRD); ...`.
3. Some action items have **no Owner line**. Fall back to `canonical_content`:
   action-item statements read "`<Actor> to <verb> ...`", so the item is the
   owner's only when `canonical_content` *begins with* the owner's name **and**
   the owner's `person/<slug>` is in `entity_refs`. Mark these **inferred —
   verify**.
4. **Exclude items where the owner is only a recipient.** "Sam to send the
   pricing sheet to Jane" is Sam's action item, not Jane's — even though
   `person/jane` is in `entity_refs`. The Owner / leading actor counts, not mere
   presence in `entity_refs`.
5. Also check `commitment/*.md` for promises the owner made — those are
   obligations too. A commitment and an action item can describe the same thing.

**Important — there is no completion state.** The signals store is an extraction
of what was *said in meetings*, not a live task tracker; there is no "done" flag,
and some items may already be complete. Present results as "action items
attributed to you across recent meetings," and surface any stated due date so the
user can judge staleness. (For mutable status + processing, use
`client-action-items`.)

## Other queries

- **Decisions / risks / questions** — scan the matching directory; filter by
  `entity_refs` for a person, project, or company.
- **What came out of a specific meeting** — filter every type by `source_ref`
  (the meeting id); `summary/` gives the overview.
- **By project** — `entity_refs` carries `project/<slug>`; group on it.

## Freshness

The newest file in `_index/` shows the date of the last extraction run. If
signals look stale — a recent meeting is missing — they're regenerated by the
company's signals pipeline; use `meeting-next-steps` for a live pull meanwhile.

## Related skills — don't confuse

- **`meeting-next-steps`** — pulls *fresh* action items directly from the
  company's meeting notes for a recent window. Use when the store is stale or you
  need meetings not yet extracted. This skill reads the already-extracted store.
- **`client-action-items`** — the mutable tracker. Consumes this skill's
  `action_item` output and adds status + processing.
- **`/crm`** — pipeline and account status. A different domain (leads/customers,
  not the owner's personal task list). Don't route "what are my action items"
  there.
