---
name: client-onboarding
description: Run the agency's onboarding system on a signed client. Reads the firm's agency playbook and the client's documents (contract, proposal, call transcript, exports), then produces a sourced client brief with open questions, an intake request plus status file, an account audit, and a kickoff package, stopping for a strategist's approval at each gate. Finishes by feeding anything the strategist caught back into the playbook. Use when a client signs, or on /practice-client.
triggers:
  - onboard this client
  - client onboarding
  - new client signed
  - prepare the kickoff package
  - audit the new client's account
  - run onboarding on practice client
maturity: HQ-native (authored for this package)
---

# /client-onboarding

Turns a signed client into an audited account and a launch plan a strategist can
review before kickoff. It follows the same sequence every time:

**review the scope → find missing inputs → audit the account → prepare the kickoff package → save what we learned**

Every step writes one file, cites its sources, and ends at a named approval
point. Nothing in this skill contacts the client. Anything outward-facing is
drafted for a human to send (policy `client-service-approval-gate-external-actions`).

## Where things live

| What | Path |
|---|---|
| Agency playbook (read) | `companies/{firm}/knowledge/agency-playbook/` |
| Engagement record (read, append) | `companies/{firm}/clients/{slug}/engagement.md` |
| Client documents (read) | `companies/{firm}/clients/{slug}/onboarding/inputs/` |
| Onboarding outputs (write) | `companies/{firm}/clients/{slug}/onboarding/` |

All of this is inside the firm company. A session bound to the firm can run the
whole skill. Run it in that session itself, not in a Task subagent: subagents
do not inherit the session's company binding and HQ blocks them from company
files. List folders with `ls` (the Read tool cannot list a directory).

If the client also has its own HQ company and you need to read
files there (for example exports the client dropped into their own HQ), add it
to this session first:

```bash
bash core/scripts/hq-session.sh add company {client-company}
```

Never copy firm-internal notes into the client's company (policy
`client-service-internal-external-split`).

## Step 0: Check the setup

1. Resolve `{firm}` from the session's bound company. If the session is not bound,
   ask which company is the agency. Do not guess.
2. Confirm `companies/{firm}/knowledge/agency-playbook/` exists. If it does not,
   stop and point the user at `/agency-setup`.
3. Resolve `{slug}`. If the user did not name a client, list
   `companies/{firm}/clients/`, skipping `_`-prefixed folders, and ask. If the
   client has no engagement folder, point at `/new-client`.
4. Gather the client's documents from their tools before asking for any.
   If `onboarding/inputs/` is missing documents, look for them yourself, by the
   client's name, domain and contacts (from `client-profile.md`):
   - **Contract and proposal** (contract, MSA, SOW, agreement, order form,
     proposal, quote): in the docs tools they have connected (Google Drive,
     Notion, Dropbox and the like), in an e-signature tool if one is
     connected, and attached to the client's deal in the CRM.
   - **Call transcript**: the full transcript of each sales or kickoff call
     with the client in their notetaker, not only its summary.
   - **Deal facts**: the deal in the CRM (amount, stage, dates, contacts).
   - **Exports**: anything their connected tools hold for the audit.
   `hq integrations list --usable --json --company {firm}` shows what is
   connected. If no docs tool is connected, offer to connect one first (any
   tool works; see how tools connect in setup), then search it.
   Save each document as markdown in `onboarding/inputs/` with a header naming
   its source (tool, title, link or id, date fetched). Never copy a credential.
   Then show the person what you found and where, in one message, and let them
   confirm or correct it. Ask them only for what you could not find; they can
   still drop files in or paste text.
   If no signed contract can be found anywhere, do not stop: use the best
   signed document there is (a signed proposal or order form, else the CRM
   deal) as the stand-in, and make "No signed contract found" a blocking open
   question in the brief. Everything else that is missing becomes a gap in
   Step 2.
5. Read every playbook file. They are the standard this client is checked against.
6. If `onboarding/status.md` exists, this is a re-run. Read its **Steps** table
   and resume at the first step that is not approved. Never overwrite an
   approved output.

### How approvals are recorded

Every numbered output file (`01-` to `04-`) starts with this front matter.
`status.md` has none; its **Steps** table is the summary.

```yaml
---
client: {slug}
step: 1
status: draft            # draft | approved
approved_by:             # the strategist's name, filled at the gate
approved_at:             # YYYY-MM-DD, filled at the gate
---
```

At each gate, ask for the approver's name, then set `status: approved`,
`approved_by` and `approved_at`, and update the matching row in the **Steps**
table at the top of `status.md`. If the user declines to approve, leave
`status: draft`, record what they want changed, and stop at that gate.

## Step 1: Review the scope → `01-client-brief.md`

Create `status.md` with the **Steps** table (template in Step 2) if it does not
exist yet.

Compare the contract, proposal and call transcript against
`scope-rules.md` and `onboarding-checklist.md`. Also check every date in the
contract (access due dates, start dates, notice periods) against today, and flag
any that have already passed.

Write a brief using the structure in `examples.md`:

- **Client and what is in scope**: brands, products, channels, deliverables,
  term and fees, each with a source (`contract.md §3`).
- **Goal**: the goal and the metric it is judged on, in the client's words, with
  the timestamp from the call.
- **Mismatches**: anything said on the call or promised in the proposal that the
  contract does not cover, and anything the contract excludes that the client
  seems to expect. Cite both sides of every mismatch.
- **Open questions**: numbered, each with an owner (account lead, client,
  strategist) and marked `blocking` if the checklist says delivery cannot start
  until it is answered.

Rules:

- The contract wins. A mismatch is an open question, never an assumption that
  the larger scope applies.
- Quote or cite. If you cannot point to the source line, the statement does not
  go in the brief.

**Approval gate 1.** Show the brief and ask the strategist to approve it or
correct it. Record their corrections in the brief. If they caught something the
brief missed, note it for Step 6.

## Step 2: Find missing inputs → `02-intake-request.md` and `status.md`

Walk `onboarding-checklist.md` line by line. For each item decide:
`received` (cite where), `missing`, or `unclear`.

An item is blocking if the checklist marks it `[blocking]` **or** the contract
makes it a client obligation (for example, access the client agreed to provide).
The contract wins over the checklist.

Fill in the **Inputs** section of `status.md`:

```markdown
# Onboarding status: {Client}

## Steps

| Step | File | Status | Approved by | Date |
|---|---|---|---|---|
| 1 Scope review | 01-client-brief.md | approved | Sam Lee | 2026-10-09 |
| 2 Missing inputs | 02-intake-request.md | draft | | |
| 3 Audit | 03-audit.md | not started | | |
| 4 Kickoff package | 04-kickoff-package.md | not started | | |
| 5 Engagement record | engagement.md | not started | | |
| 6 Playbook learnings | knowledge/agency-playbook/learnings.md | not started | | |

## Inputs

| Item | Status | Source or note | Blocking |
|---|---|---|---|
```

Then draft `02-intake-request.md`, a message to the client that:

- thanks them and confirms what they already sent, so they do not resend it;
- pre-fills what they already told you, so they only confirm it;
- asks for each missing asset, access grant and approval contact, in plain
  language, grouped by who on their side can answer;
- puts the blocking items first.

Use the agency's voice from `agency-profile.md`.

**Approval gate 2.** The intake request is a draft. Show it and say plainly that
nothing has been sent. Approving it means the content is approved; it does not
send it. The strategist sends it, or approves it for a sending
flow they choose. Update `status.md` as items arrive on later runs.

## Step 3: Audit the account → `03-audit.md`

Work through `audit-criteria.md` using the exports and documents in `inputs/`.

- Calculate from the data. Show the formula or the rows used for every number
  (for example, `spend share = 18,400 / 40,000 = 46%, campaign-export.csv rows 2 to 6`).
- Lead with the gap between what the client wants and what the current setup
  rewards. That is usually the headline.
- Follow results as far toward revenue as the data allows, and say where the
  trail ends.
- When the data does not support a conclusion, write
  **"Not supported by the data provided"** and name the data that would settle
  it. Never fill a gap with an estimate (policy
  `agency-kit-evidence-before-commitment`).
- Mark anything that touches work outside the contract as out of scope, and link
  it to the open question from Step 1.

**Approval gate 3.** Show the audit's findings in a few plain sentences, then
the file. The strategist confirms or corrects each finding.

## Step 4: Prepare the kickoff package → `04-kickoff-package.md`

Turn the approved findings into a plan:

- **Proposed tests and changes**, each with: why (the finding and its source),
  what, depends on, success measure, and who must approve.
- **Briefs** for any creative or content work, following `examples.md`.
- **Tracking or measurement fixes**.
- **Dependencies and order**: what is blocked by a missing input from Step 2.
- **Not included**: recommendations that need a scope change, listed separately
  with the contract clause, so the account lead can decide whether to quote them.

Nothing in this package is a client commitment yet.

**Approval gate 4.** The strategist reviews the package. Only after their
approval does anything go to the client, and sending is still a separate,
explicitly approved action.

## Step 5: Update the engagement record

Add to `companies/{firm}/clients/{slug}/engagement.md`, following each section's
own order (Timeline is newest first, so add at the top). Replace a section's
template placeholder lines (such as `TODO`) when you add the first real entry;
leave every other line alone.

- under **Timeline**, one dated line: "Onboarding package approved by {name}",
  using the `approved_by` from `04-kickoff-package.md`.
- under **Awaiting client**, each blocking item still missing from `status.md`.
- under **Decisions**, each open question the strategist answered, with the answer.

Do not rewrite other sections. The engagement record is the source of truth
(policy `client-service-engagement-is-source-of-truth`).

## Step 6: Save what we learned

Ask the strategist one question: *"Did you catch anything this process should
have caught on its own?"* Also include anything they corrected at gates 1 to 4.

For each lesson:

1. Add a row to `knowledge/agency-playbook/learnings.md`.
2. Make the matching change to the playbook file that should have caught it:
   a new line in `onboarding-checklist.md`, a new criterion in
   `audit-criteria.md`, or a new rule in `scope-rules.md`. Show the change and
   get a yes before writing it.

That is how the next client starts with a better process (policy
`agency-kit-playbook-learns`).

If there are no lessons, change nothing in the playbook and say so in the report.

## Report

End with a short summary: the five files written (`01-client-brief.md`,
`status.md`, `02-intake-request.md`, `03-audit.md`, `04-kickoff-package.md`), how
many open questions are blocking, what is waiting on the client, and the single
most important finding.

## Practice mode

If `{slug}` is `practice-northwind`, say at the start that this is the practice
client with invented data. Work only from the files in the client's
`onboarding/inputs/`. When the run is finished, continue with Step 5 of
`/practice-client` (grading) if it started this run; otherwise tell the user to
run `/practice-client` to grade it.
