---
name: proposal-from-audit
description: Turn an approved conversion audit into a Page Sprint proposal: the top experiment as the scope, the page, the metric and baseline, what is in and out, the package price and timeline from the rate card, and the evidence section quoted from the audit. Draft only.
triggers:
  - proposal from the audit
  - page sprint proposal
  - propose the next step
  - turn the audit into a proposal
maturity: HQ-native (authored for this package)
---
# /proposal-from-audit

## Inputs

The approved audit in `funnel-audit/`, the playbook's services and rate
card, the scope rules, and the agency's voice.

## Method

1. Take the top experiment from the audit: hypothesis, page, metric,
   evidence. That is the scope, in one paragraph, precise enough to become
   the SOW.
2. Match it to the package in the rate card (a Page Sprint when there is
   one; otherwise the closest package, named) and take its price and
   timeline from there. Never quote a price not in the rate card.
3. Write the proposal with the `proposal` skill's structure, and these
   specifics:
   - **Why this page**: the evidence from the audit, quoted with sources.
   - **What we will do**: the change, the build, the test, the readout.
   - **What we will measure**: the metric, its baseline from the export,
     the minimum detectable effect, and the weeks from `sample-size-check`.
   - **In scope / out of scope**: from the scope rules; the other audit
     experiments listed as out of scope for this sprint.
   - **What we need from you**: access, approvals, the permissions for
     proof.
   - **Price and timeline**: from the rate card.
4. Save to `companies/{firm}/knowledge/proposals/{slug}/{YYYY-MM-DD}-page-sprint.md`
   with the draft front matter.

## Rules

- No promise of a lift. The proposal promises a test and a readout.
- Everything in the evidence section traces to the audit.
- Draft only; the account lead approves and sends.
