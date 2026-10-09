---
name: track-project
description: Roll up story pass/fail state across a client's projects, refresh engagement.md, draft a plain client-facing status update, and (portal slot bound and approved) publish it. Never publishes firm-internal state.
args:
  - client_slug: client key
  - publish: "'false' (default) or 'true' to attempt publish_update behind the approval gate"
allowed-tools: Read, Write, Edit, Bash(bash core/workers/public/client-services/scripts/slot-state.sh:*), Bash(bash core/workers/public/client-services/scripts/engagement-layout.sh:*), Bash(ls:*)
---

# track-project — status rollup and client update

Formalizes the PRD-as-tracker pattern. The `prd.json` files **are** the task
tracker: each story carries `passes: true|false` plus title, priority and file
list. This skill rolls that up, refreshes canonical engagement state, drafts a
client-facing update, and publishes it only through the portal slot, only when
asked, and only behind the gate.

## Governing policies (load and honor)

- `client-service-engagement-is-source-of-truth`
- `client-service-internal-external-split`
- `client-service-approval-gate-external-actions`

## Steps

0. **Resolve the layout first.** Never hard-code where this firm's files live —
   ask the config:

   ```bash
   bash core/workers/public/client-services/scripts/engagement-layout.sh \
     --firm {firm} --engagement {client_slug} --expand
   ```

   It reports the canonical `engagement_path`, the resolved `tracker_sources`
   globs, the matched tracker files, and the local general `dedupe_key` — each
   tagged with whether it came from a per-engagement override, the firm's layout,
   or the pack default. It is read-only and makes no external call.

   The general key is all this skill needs; it makes no external write. A skill
   that *does* write must resolve the key for its own slot (`--slot <name>`),
   because a firm's slots may join on different values.

   `tracker_sources_state: declared-none` means the firm has said it keeps no
   trackers this pack can read. Report "no tracker" and stop looking; do not fall
   back to the default glob.

1. **Read the trackers** — every file the resolver matched. Per story: `passes`,
   title, priority, and any completion or in-progress marker.

   Two shape rules, because real tracker files vary:
   - the story array is `userStories` **or** `stories` — read whichever key is
     present, and `userStories` if both are;
   - a story with **no `passes` key is undeclared, not failing**. Count it
     separately and say so. Never resolve absent to `false`.

2. **Roll up per project:**
   - stories total, passing, remaining, and undeclared (no `passes` key);
   - the named in-flight stories (id plus title);
   - anything blocked or at risk, and what it is waiting on.

   Report the rollup as counts you can point at in the files. If a matched
   project has no tracker file, say the project has no tracker — do not estimate
   a percentage.

3. **Update the engagement record** at the `engagement_path` step 0 resolved —
   not a path you assembled yourself. Client-visible milestones and status go in the
   shared sections; coordination notes, internal owners and commentary go in the
   internal section. The engagement record is the thing you are updating; the
   client-facing update in step 4 is derived from it.

4. **Draft the client-facing update.** Plain, outcome-first prose: what shipped,
   what is in flight, what is blocked or waiting on them. No story ids, no
   internal jargon, no margin or pipeline commentary. **Assemble it from the
   client-visible sections only** — never write the whole file and redact.

5. **Portal slot.** Only when `publish=true`:

   ```bash
   bash core/workers/public/client-services/scripts/slot-state.sh --firm {firm} --slot portal
   ```

   - **bound:** present the exact update — title, body, links, and which surface
     it lands on — and **wait for explicit approval**. On approval,
     `publish_update(engagement, {title, body, links})`. If the update references
     work product, `share_artifact(engagement, artifact_ref, {label, kind,
     visibility})` — `artifact_ref` is a **reference, never bytes**; this pack
     does not store, upload, render or version work product. `share_artifact` is
     its own gate.
   - **empty:** report `portal slot is not configured (empty — the firm runs no
     client-facing tool)`, save the update as a dated note in the engagement
     folder, and publish nothing. The firm delivers it however it already does.
   - **undeclared:** report `portal slot is not declared`, suggest
     `/onboard-firm`, and do the same local-note path. Do not treat it as empty.

   When `publish=false`, do not resolve or report the portal slot as if it had
   been part of the run — say the publish was not requested.

6. **Save the rollup** to
   `workspace/reports/{firm}/client-services/{date}-client-services-track-project.md`
   and present the draft update for review.

## Done when

- The engagement layout was resolved from the config before any file was read,
  and the report names which tracker sources it used.
- Every project's pass/fail rollup is captured from real tracker state, with
  undeclared stories counted as undeclared and never as failures.
- `engagement.md` reflects current status, with the internal/external split intact.
- A client-facing draft exists that contains no firm-internal state.
- The update was published only with a bound portal slot and an explicit
  approval; otherwise the slot state is reported and the note is local.
