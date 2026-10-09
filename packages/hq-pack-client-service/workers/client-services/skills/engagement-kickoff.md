---
name: engagement-kickoff
description: Run the post-signature kickoff — read whatever call and channel record the transcripts slot can reach, lay down the client knowledge base (kickoff notes, systems-access inventory, action items), draft the capability roadmap as a decision queue, and plan phased invites and training. Never sends, invites or requests access without per-action approval.
args:
  - client_slug: client key
  - client_co: optional isolated HQ company holding the client KB
  - since: optional ISO date bounding the call/channel window
allowed-tools: Read, Write, Edit, Grep, Bash(bash core/workers/public/client-services/scripts/slot-state.sh:*), Bash(ls:*)
---

# engagement-kickoff — from signed agreement to working engagement

Runs after the agreement is signed and the first call has happened or is booked.
Turns scattered kickoff intel into a structured knowledge base, an action
tracker, a capability roadmap and an invite plan. Picks up where
`new-engagement` left off.

## Governing policies (load and honor)

- `client-service-engagement-is-source-of-truth`
- `client-service-internal-external-split`
- `client-service-approval-gate-external-actions`

## Hard rules for this skill

- **Nothing outward without per-action approval.** No message to a shared
  channel, no email, no invite, no access request. Drafts only, one approval per
  send. Never click or trigger a "request access" control on the client's behalf.
- **Credentials never travel inline.** A client-supplied credential goes into the
  vault through the HQ secret workflow, and the knowledge base records the vault
  **name** only. A credential found sitting in a channel or a document is flagged
  for rotation — never copied into a file, never printed.
- **Access grants get a written record** (system, scope, grantee, date, vault
  secret name) in the systems-access inventory.

## Steps

1. **Resolve context.** Bind the session to the firm (and `client_co` when the
   client has its own company). Read
   `companies/{firm}/clients/{client_slug}/engagement.md` and list its open
   `TODO:` lines — they become tracker rows in step 4.

2. **Resolve the transcripts slot before reading anything:**

   ```bash
   bash core/workers/public/client-services/scripts/slot-state.sh --firm {firm} --slot transcripts
   ```

3. **Get the call record, according to the state. Never fabricate one.**
   - **bound (tool binding):** `list_calls(engagement, since)` over the window,
     then `fetch_transcript(call_ref)` for each. Convert every timestamp to a
     readable date in your notes.
   - **bound (pointer binding):** `list_calls` is **unsupported** here — say so
     plainly, do not guess a list. `fetch_transcript` returns the pointer
     location; the document *is* the answer. Read it.
   - **empty:** report `transcripts slot is not configured (empty — the firm runs
     no capture tool)`. Work from whatever notes the operator has already pasted
     into the engagement folder. Poll nothing.
   - **undeclared:** report `transcripts slot is not declared`, suggest
     `/onboard-firm`, and work from the engagement folder the same way.
   - In every non-bound case: record the gap as an action item (get a recap from
     whoever ran the call; decide how future calls get captured). A missing call
     record is a tracked gap, never an inferred summary.

4. **Lay down the client knowledge base.** Under the client's knowledge home:
   - `operations/kickoff-notes.md` — the call record and channel digest, and what
     each item actually establishes. Cite the source of every claim.
   - `operations/systems-access.md` — per-system table: system, status, scope,
     grantee, date, **vault secret name**, and the written grant record. Plus the
     open access work.
   - `operations/action-items.md` — a numbered tracker with owners and status,
     carrying forward the engagement record's open TODOs.
   - Update `engagement.md`: status, full contact roster, timeline, awaiting-client
     list. Firm-side coordination stays in the internal section.

5. **Capability roadmap as a decision queue.** From the ingested material, draft
   candidate skills, knowledge and integrations for this client. Present them to
   the owner as a numbered queue, **one question at a time**. Build nothing
   speculative and nothing unapproved.

6. **Invite and training plan.** Build the roster from the kickoff attendees.
   Write `operations/training-plan.md`: phased invites (pilot, then team, then
   cadence) with proposed roles and a reusable session outline. Prerequisite:
   never invite people into an empty workspace — the first capabilities exist
   before phase one. Invites are outward actions: **one approval per send**.

7. **Wrap.** Commit the client knowledge repo if the firm keeps one, refresh the
   search index, and report the action-item list and the decision queue.

## Outputs

- `operations/{kickoff-notes,systems-access,action-items,training-plan}.md`
- Updated `engagement.md` (status, roster, timeline, awaiting items)
- A capability-roadmap decision queue presented one question at a time

## Done when

- The knowledge base exists and every claim in it cites its source.
- The transcripts slot state was resolved and reported; where it was unbound, the
  gap is an action item and no call record was invented.
- No message, invite or access request left the building without its own approval.
- No credential value appears in any file — vault names only.
