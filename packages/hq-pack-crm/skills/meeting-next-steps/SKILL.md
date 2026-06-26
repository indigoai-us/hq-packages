---
name: meeting-next-steps
description: Pull a company's recent meeting notes, resolve attendees against its pipeline/CRM, and synthesize prioritized next steps per meeting. Use when the user asks "what are my next steps from this week's meetings", "follow-ups from my calls", "prep for my next touchpoint with {company}", or any variation combining recent meetings + CRM context + action planning. Company-agnostic: resolves the meeting source and pipeline from companies/{co}/client-management.yaml. Read-only.
allowed-tools: Bash, Read, Grep
---

# Meeting next steps

Pull a company's recent **meeting notes**, enrich attendees with pipeline/CRM
context (person → company → open deal), and produce a prioritized,
account-grouped action plan. Read-only — never sends anything.

## Resolve context first

Read `companies/{co}/client-management.yaml`:

- **`meetings.source`** — where meetings come from:
  - `hq-meeting-notes` → `hq meetings list --company {co} --json`
  - `recall` / `fireflies` / other → drive the connection referenced by the
    `meetings` silo (`silos.meetings.connection`).
- **`silos.pipeline`** — for attendee → account/deal enrichment:
  - `connected` → use the referenced connection's read capability (creds via
    `hq secrets exec --only <KEY> -- …`; never print the key).
  - `native` → resolve attendees against ontology `company`/`contact`/`deal`
    entities via `/crm`.
- **`stages`** — the pipeline stage vocabulary, for stage-appropriate motion.

If `meetings.source` is unset or the store is empty for the window, say so —
don't invent meetings.

## When to trigger

- "Next steps from my meetings this week?" / "Follow-ups for my call with {name}"
- "Prep me for {company}'s next touchpoint" / "What did I commit to yesterday?"
- "Roll up action items from the last {N} days"

Do **not** trigger for: scheduling new meetings; analyzing a single transcript
the user already pasted (just do it inline); anything outside this company's
meeting/CRM context.

## Execution

1. **List recent meetings** (newest first), filter to the window:

   | User phrasing | Window |
   |---|---|
   | "this week", "recent", unspecified | 7d (default) |
   | "last two weeks" | 14d |
   | "since {date}" | YYYY-MM-DD |
   | "today" | 1d |

2. **Pull notes per in-window meeting.** The notes summary + recorded action
   items are the primary synthesis input; pull the verbatim transcript only when
   the user needs quotes.
3. **Resolve external attendees** against the pipeline silo to attach company +
   open-deal + stage context. Degrade gracefully when a lookup fails (show
   person + company, skip stage, note "(no deal context)"). Write large
   intermediate JSON to `workspace/` and read it back rather than holding it
   inline. Never wrap a secret-injecting command in `$(...)` or pipe it anywhere
   that could leak the key.

## Synthesis — output structure

```markdown
# Meeting Next Steps — {date range}

**Pulled:** {meeting_count} meetings · {matched}/{external} external attendees matched

---

## {Account Name} — {Stage if any} · {Deal Value if any}

### {Meeting Title} — {YYYY-MM-DD}
*Attendees:* {external names only}

**Captured from notes:**
- {1-3 bullets from the notes summary}

**Action items recorded in the notes:**
- {one per line, if present}

**Recommended next steps (ranked):**
1. **{action}** — {one-line justification grounded in stage / recency / what was said}
2. …
```

### Ranking heuristics (generic)

Order next steps within a meeting by:

1. **Explicit commitments the owner made** ("I'll send the contract Friday") —
   non-negotiable.
2. **Blockers the prospect raised** ("we need pricing for 500 seats") — answering
   unblocks the deal.
3. **Stage-appropriate motion** (map to this company's `stages`):
   - early/discovery → schedule a value/technical deep-dive; find the economic buyer.
   - eval/demo → send a tailored proof artifact (case study, ROI model, security doc).
   - negotiation → tighten scope/pricing; surface and remove objections.
   - won → kickoff + success plan.
   - lost/cold → check-in only if there's a real new wedge.
4. **Recency/aging** — meetings older than 5 days get a "this is slipping" flag.

### Cross-account roll-up

```markdown
## Cross-Account Priorities

**Top 3 things to do tomorrow:** 1… 2… 3…

**Unmatched attendees (consider adding to CRM):**
- {email} (from "{meeting title}")
```

## Edge cases

- **No meetings in window** → "No meeting notes since {since}. Widen the window?"
- **All attendees internal** → skip that meeting; note the count in the header.
- **Pipeline lookup fails** → degrade gracefully (above).
- **Notes pending** → include with a "⏳ notes pending" flag, don't skip.

## What this skill does NOT do

- Does not write back to the CRM, send email/Slack, or create calendar invites —
  it produces a plan. If the user wants those actions, offer to draft inline for
  manual send, or hand off to a write-capable capability with explicit approval.
- Does not read full transcripts by default — only the notes summary.

## Related

- **`client-signals`** — reads the already-extracted signals store. Use it for
  "what are my action items" off historical extraction. This skill pulls *fresh*
  from meeting notes for a recent window.
- **`/crm`** — the canonical account record this skill enriches against.
