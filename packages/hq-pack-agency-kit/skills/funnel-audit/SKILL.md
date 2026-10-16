---
name: funnel-audit
description: Run the agency's conversion audit on a client. Reads the client's inputs (brand guide, product details, competitors, proposal or SOW, CRM export, analytics export) and call transcripts, scores the client's site against the playbook's audit criteria with the evidence quoted for each criterion, and ranks the top five experiments. Publishes the draft to a password-protected review page for the team, revises on comments, and logs the approval. Use for "run the conversion audit for {client}", "funnel audit", "audit {client}".
triggers:
  - run the conversion audit for
  - conversion audit
  - funnel audit
  - audit the funnel
maturity: HQ-native (authored for this package)
---

# /funnel-audit

The agency's audit workflow for conversion work. It scores a client's funnel
against the agency's own audit criteria using only the client's data, and
turns the scores into a ranked list of experiments the team can review. It is
a comparison between what the site says and what the data says, never an
opinion about design. A finding with no data behind it does not go in.

## Where things live

| What | Where |
|---|---|
| Agency playbook, audit criteria (read) | `companies/{firm}/knowledge/agency-playbook/audit-criteria.md` |
| Client workspace (read) | `companies/{firm}/clients/{slug}/` |
| Client inputs (read) | `companies/{firm}/clients/{slug}/onboarding/inputs/` |
| Transcripts (read) | the notetaker, or the transcripts folder in Drive or Notion, saved into `onboarding/inputs/transcripts/` |
| The audit (write) | `companies/{firm}/clients/{slug}/funnel-audit/{YYYY-MM-DD}-audit.md` |
| The review page (write) | `companies/{firm}/clients/{slug}/funnel-audit/review/index.html` |

## Step 0: Gather what the client knows

1. Resolve `{firm}` and `{slug}` as `client-onboarding` does. The playbook must
   exist; the client must have a workspace.
2. Read the audit criteria in full. They are the standard; the audit has one
   section per criterion, in the playbook's order, scored the playbook's way.
   If the playbook has no audit criteria, say so and stop.
3. Read the client's inputs from the workspace. Onboarding and setup copy the
   client's documents from the agency's tools into `onboarding/inputs/`: the
   brand guide, product details, competitors, proposal or SOW, the CRM export
   (deal stage, lost reasons, closed-won titles) and the analytics export
   (exits and bounce by page and device). If a document is missing from the
   workspace, look for it in the agency's tools by the client's name, the
   way onboarding does, and save a copy with a header that names its source.
4. Read the transcripts if there are any: the notetaker, or the transcripts
   folder in Drive or Notion, searched by the client's name. Save each into
   `onboarding/inputs/transcripts/` with its date and attendees at the top.
5. Fetch the client's current site, page by page (home, pricing, product,
   security, contact and whatever the nav links), the way `site-build` does.
6. Say which sources were checked and what came from each, and what is
   missing. The CRM export, the analytics export and the current site are
   required: the criteria cannot be scored without them. Everything else
   improves the result, and its absence is noted in the audit under the
   criteria it would have informed.

## Step 1: Score → `{YYYY-MM-DD}-audit.md`

Front matter as in `client-onboarding` (`client`, `step: audit`,
`status: draft`, `approved_by`, `approved_at`), then:

- **Summary.** Three lines: who actually buys (the modal closed-won title and
  segment, from the CRM export), the biggest leak (the page with the highest
  exit rate, from the analytics export), and the one change that follows.
- **Scores.** A table of every criterion with its score (the playbook's
  scale) and a one-line reason.
- **One section per criterion**, in the playbook's order:
  - **Evidence.** Quote the data. CRM lost reasons with their counts ("thought
    it was a developer tool: 5 of 12 lost deals, CRM export rows 15, 19, 23,
    27, 31"). Analytics exits and bounce by page and device ("pricing exit
    rate 71%, mobile bounce 68% against desktop 41%, Analytics export rows 4
    and 9"). Transcript lines with their timestamp ("2026-09-09 sales
    interview, Priya Sandoval at 00:04: 'they ask the price question on every
    call'"). The site's own words, quoted. Every quote names its source
    document and row, section or timestamp.
  - **Severity.** The score and what it costs, tied to the number that shows
    it. When the data cannot settle a criterion, write "Not supported by the
    data provided", name the data that would, and leave the score blank.
  - **Recommended test.** One concrete change on one page, with the metric
    that would show it worked.
- **Prioritized experiments.** The top five, ranked the playbook's way
  (expected lift by ease). Each: hypothesis ("If we ... then ... because
  ..."), the page, the metric, and the evidence (the criterion and the quoted
  data point it comes from, with its source).
- **Data gaps.** What was missing and what it would have changed.

Every claim cites its source document. Never invent a number, a quote, a
customer name or a result. Never average or divide numbers from different
periods (policy `agency-kit-evidence-before-commitment`).

## Step 2: Review page → `review/index.html`

Render the audit as one self-contained HTML page in the agency's own look
(`knowledge/agency-playbook/brand.md`; the kit's brand when there is none):
the summary, the scores table, the eight sections, the experiments. Mark it
"Draft for review" at the top. Readable on a phone, no external scripts,
fonts from Google Fonts at most.

Publishing puts the page on the web, so ask first. Deploy `review/` with
HQ's deploy skill (`.claude/skills/deploy/SKILL.md` in the HQ folder),
behind a password, with comments turned on, and give the link and password
to the account lead. It is a draft for the team to review; nothing goes to
the client. Record the link in the audit file.

**Approval gate.** The account lead approves the audit or asks for changes.
Changes come as a message or as comments on the review page (read with the
deploy skill's owner comment routes). Revise the audit, record what changed
under `## Revisions ({date})`, re-render and redeploy the page to the same
link, and say what changed. Keep `status: draft` until approved.

## Step 3: Record and offer the next step

On approval set `status: approved`, `approved_by` and `approved_at` in the
audit file. Add to `companies/{firm}/clients/{slug}/engagement.md`: a
Timeline line ("Conversion audit approved by {name}"), the review link under
Decisions, and the data gaps under Awaiting client. Then offer the next
step: a Page Sprint proposal built from the top experiment (the `proposal`
skill, with the experiment's hypothesis, page and metric as its scope), or a
site rebuild of that page (`site-build`).

## Never

- Never score without the CRM export, the analytics export and the current
  site.
- Never invent a number, a quote or a customer name; a finding without a
  source is left out.
- Never publish without an explicit yes, and never send anything to the
  client. The review link is for the team.
- Never mark the audit approved without an "Approve" from the person.
