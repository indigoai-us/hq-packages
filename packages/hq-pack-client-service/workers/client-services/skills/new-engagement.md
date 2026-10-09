---
name: new-engagement
description: Open a brand-new client engagement — guard against clobbering an existing one, create the client home under the firm, seed engagement.md from the firm's own template with unknowns left as explicit TODOs, and (portal slot bound and approved) publish a first client-facing entry. Optionally provisions an isolated client company.
args:
  - client_slug: client key, lowercase, no spaces
  - display_name: human display name for client-facing surfaces
  - client_co: optional isolated HQ company for the client (default: none — the engagement record lives under the firm)
  - publish: "'false' (default) or 'true' to attempt a first portal publish behind the approval gate"
allowed-tools: Read, Write, Edit, Bash(bash core/workers/public/client-services/scripts/slot-state.sh:*), Bash(ls:*), Bash(grep:*)
---

# new-engagement — open a client from nothing

Takes a client from nothing to a seeded, canonical `engagement.md` and, only if
the firm has a client-facing surface bound and a human approves, a first
published entry. This is the front door; `engagement-kickoff` picks it up after
signature.

This skill **orchestrates** — it never reimplements the firm's onboarding
(`/onboard-firm` owns `client-service.yaml`) and never hand-rolls an integration
that has an adapter operation.

## Inputs

- `client_slug` — client key.
- `display_name` — how the client is named on client-facing surfaces.
- `client_co` — OPTIONAL isolated HQ company, only for a client that needs its
  own vault or secrets. The engagement record does **not** require one; it always
  lives at `companies/{firm}/clients/{client_slug}/`.
- `publish` — `false` by default. Nothing reaches a client without both a bound
  portal slot and an explicit approval.

## Governing policies (load and honor)

- `client-service-engagement-is-source-of-truth`
- `client-service-internal-external-split`
- `client-service-approval-gate-external-actions`

## Steps

1. **Resolve and guard.** Resolve the firm from the session and `client_slug` /
   `display_name` from the args.
   - **Refuse to clobber:** if `companies/{firm}/clients/{client_slug}/` already
     exists, STOP. This is an existing engagement — route to `track-project` or
     `deal-pipeline` instead.

2. **Resolve the slots you may need**, before writing anything:

   ```bash
   bash core/workers/public/client-services/scripts/slot-state.sh --firm {firm} --slot portal
   bash core/workers/public/client-services/scripts/slot-state.sh --firm {firm} --slot crm
   ```

   Record each state as `bound`, `empty` or `undeclared` — three states, reported
   in those words, never collapsed to two. If the firm has no
   `client-service.yaml` at all, every slot is `undeclared`: say so, suggest
   `/onboard-firm`, and continue with the local-only path below. That is a
   complete, supported run, not a failure.

3. **Research public background (optional, public sources only).** What the
   company does, size, leadership. This is **context, not engagement state** —
   never assert it as a commitment. Record source links under the internal
   section of the engagement record.

4. **Create the client home** at `companies/{firm}/clients/{client_slug}/`.
   - Only if the client needs its own isolated vault or secrets, also provision
     `client_co` as a separate HQ company. Skip by default.

5. **Seed `engagement.md`** from the firm's own template
   (`companies/{firm}/clients/_templates/engagement.template.md` when present;
   otherwise ask the firm for one rather than inventing a house format):
   - fill only facts you actually have;
   - leave every unknown as an explicit `TODO:` — contacts, kickoff, cadence,
     scope, commercial terms;
   - status stays pre-signature until a signed agreement exists;
   - research provenance and any firm-side prep go under the **internal**
     section, which never crosses a client-facing operation.

6. **Portal slot — first client-facing entry.** Only when `publish=true`.
   - **bound:** assemble a client-safe entry from the client-visible sections
     only. Present it in full — the exact copy, the surface it lands on, what the
     client will see — and **wait for explicit approval**. On approval call
     `publish_update(engagement, {title, body, links})`. Record the returned
     reference in `engagement.md`.
   - **empty:** report `portal slot is not configured (empty — the firm runs no
     client-facing tool)`. Write the same content as a dated note in the
     engagement folder. Publish nothing. Surface any `recommended:` hint once and
     record the decline.
   - **undeclared:** report `portal slot is not declared`, suggest
     `/onboard-firm`, write nothing outside the engagement folder.
   - When `publish=false`, skip the call entirely and say the publish was not
     requested — do not report a slot state you did not resolve for a reason.

7. **CRM slot — optional mirror.** Never blocking, never source.
   - **bound:** `resolve_dedupe_key(engagement, crm)` locally and purely —
     `engagement-layout.sh --firm {firm} --engagement {slug} --slot crm`, no tool
     call — then search-then-create with `upsert_company` and `upsert_deal` keyed
     on it. The key is per SLOT: reusing another slot's value makes the search
     unmatchable and creates a duplicate. `state: declared-none` means the key is
     unresolved — report it and skip the write.
   - **empty / undeclared:** report the state and skip. Engagement state stays in
     `engagement.md` and nothing else happens.
   - A CRM failure is a **warning**. It never changes engagement state and never
     fails this skill.

8. **Report** to
   `workspace/reports/{firm}/client-services/{date}-client-services-new-engagement.md`:
   what was created, what is confirmed versus still `TODO`, the resolved state of
   every slot touched, and whether a publish happened, was held at the gate, or
   was skipped because the slot is unbound.

## Done when

- `companies/{firm}/clients/{client_slug}/engagement.md` exists, seeded from the
  firm's template, with unknowns as explicit `TODO:` lines and nothing invented.
- Every slot this run touched was resolved and reported by state.
- Nothing was published without a bound slot **and** an explicit approval.
- The report exists and its slot states match what the resolver printed.
