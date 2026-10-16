---
name: site-build
description: Rebuild a client's website from the client's own data. Reads the brand guide, product details, competitors, CRM export, analytics and sales call transcripts, plus the current site, then produces an evidence brief, a new static site in the client's brand, and a before/after document where every change cites a data point. Publishes to a review link (password by default) and records approvals. Use for "new site for {client}", "rebuild {client}'s landing page", "page sprint".
triggers:
  - new site for
  - rebuild the site
  - rebuild the landing page
  - page sprint
  - site build
maturity: HQ-native (authored for this package)
---

# /site-build

The agency's fulfilment workflow for web and conversion work. It turns what the
agency already knows about a client into a finished site the account lead can
review, in the client's brand, with the reasoning attached. It is only as good
as the data behind it: a change with no data point behind it does not go in.

## Where things live

| What | Where |
|---|---|
| Agency playbook (read) | `companies/{firm}/knowledge/agency-playbook/` |
| Client workspace (read) | `companies/{firm}/clients/{slug}/` |
| Client inputs gathered for this build (write) | `companies/{firm}/clients/{slug}/site-build/inputs/` |
| Build outputs (write) | `companies/{firm}/clients/{slug}/site-build/` |
| The new site (write) | `companies/{firm}/clients/{slug}/site-build/site/` |

## Step 0: Gather what the client knows

1. Resolve `{firm}` and `{slug}` as `client-onboarding` does. The playbook must
   exist; the client must have a workspace.
2. Read every playbook file. The audit criteria are the standard the current
   site is judged against; the scope rules say what the agency may change
   (copy, structure, layout) and what it may not (logo, colors, legal claims)
   without written approval.
3. Gather the client's data from the agency's tools before asking for any,
   the same way onboarding does: the docs tool (Drive, Notion) for the brand
   guide, product details, competitor list and any exports; the notetaker or
   the Drive/Notion transcript folder for every call with the client; the CRM
   for deals and lost reasons; the client's own website, fetched page by page
   (home, pricing, product, security, contact and whatever the nav links).
   Save a copy of each as markdown in `site-build/inputs/` with a header that
   names its source. Never copy a credential.
4. Say which sources were checked and what came from each. Ask only for what
   is missing. A brand guide and the current site are required; everything
   else improves the result and its absence is noted in the brief.

## Step 1: Evidence brief → `01-evidence.md`

Write what the data says, every line with its source:

- **Who actually buys.** From the CRM export: the segment, company size and
  buyer title of closed-won deals, and what closed-lost deals say. From the
  transcripts: what the sales team hears. One paragraph, then the ICP in one
  sentence.
- **Why visitors do not convert.** From analytics (exit and bounce by page,
  conversions by page and device) and from lost reasons: the three biggest
  leaks, each with the number.
- **What the current site says, and to whom.** Walk the current site against
  the audit criteria: message match, pricing clarity, proof, CTA hierarchy,
  objection handling, form friction. One finding per criterion, quoting the
  site.
- **Competitors.** How each positions and prices, in one line each, and the
  gap the client can own.
- **The plan.** The page list (from the SOW, or the audit's priorities when
  there is no SOW), and for each page the message hierarchy: headline, who it
  speaks to, the one primary action, the proof it uses, the objection it
  answers. Each decision names the data point behind it.
- **Open questions.** Anything the data cannot settle (for example an
  attachment in the transcripts to a line the data says to drop), for the
  account lead to take to the client.

Front matter as in `client-onboarding` (`client`, `step: 1`, `status: draft`,
`approved_by`, `approved_at`).

**Approval gate 1.** The account lead confirms the plan. Nothing is built
before this.

## Step 2: Build → `site/`

Build a static site: one `index.html` plus one file per planned page, a
shared `styles.css`, the client's `logo.svg` (taken from the current site,
never redrawn) and a `<meta name="description">` per page.

Rules:

- **Brand.** Colors, fonts and logo exactly as the brand guide and current
  site have them; put the tokens on `:root`. The agency changes words,
  structure and layout, not the brand.
- **Message match.** The hero speaks to the buyer who closes, in their words
  from the transcripts and the brand voice. One primary call to action per
  page, sized as the primary; a secondary one only when the plan says so.
- **Proof only from the data.** Customer names come from the CRM or the
  transcripts, with the segment they prove. Quotes are only what the data
  records as said; otherwise use a factual line ("Used by operations teams at
  Ravelin Logistics and Quarry Health"). Never invent a testimonial, a logo, a
  number or a certification (policy `agency-kit-evidence-before-commitment`).
- **Pricing.** Show what the product details say: plans, prices, minimums,
  the trial if there is one. If pricing is "contact us" by the client's own
  choice, say so and make the form short.
- **Objections.** A security or trust section when the data shows buyers ask
  (certifications, SSO, data handling, from the product details only).
- **Forms.** Only the fields the data justifies; a trial or demo request
  needs name, work email and company at most.
- **Quality.** Valid HTML, readable on a phone, no external scripts, fonts
  from Google Fonts at most, all links resolve, images only as inline SVG or
  files you created.

## Step 3: Before and after → `02-before-after.md`

One table: page, before (quote the current site), after (quote the new site),
why (the data point, with its source file and line or row). Then a QA
checklist you ran: links, mobile layout, forms, brand compliance, every proof
item traced. Front matter as in step 1 (`step: 2`).

**Approval gate 2.** The account lead reviews the before/after and the site.

## Step 4: Publish for review

Publishing puts the site on the web, so ask first. Deploy `site/` with HQ's
deploy skill (`.claude/skills/deploy/SKILL.md` in the HQ folder), behind a
password by default, and give the link and password to the account lead. On
an explicit "make it public", redeploy it public. Record the link in
`02-before-after.md`. Nothing is sent to the client; the account lead shares
it.

## Step 5: Record and learn

Add to `companies/{firm}/clients/{slug}/engagement.md`: a Timeline line
("Site rebuild published for review, approved by {name}"), the review link
under Decisions, and any open questions under Awaiting client. Then ask the
account lead one question, as onboarding does: "Did you catch anything this
process should have caught on its own?" Each lesson becomes a row in
`knowledge/agency-playbook/learnings.md` and, with a yes, a line in the audit
criteria or the site-build SOP.

## Never

- Never build without the brand guide and the current site.
- Never put a claim on a page that no input supports.
- Never publish without an explicit yes, and never make a site public
  without a second explicit yes.
- Never change a client's logo or colors.
