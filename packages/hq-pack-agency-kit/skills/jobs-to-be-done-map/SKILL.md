---
name: jobs-to-be-done-map
description: Map the jobs the client's customers hire the product for, from interviews, reviews and the CRM, into a table of job, situation, desired outcome, current alternative and the page that should speak to it.
triggers:
  - jobs to be done
  - jtbd map
  - what job does the product do
  - map the jobs
maturity: HQ-native (authored for this package)
---
# /jobs-to-be-done-map

## Inputs

Any of: an interview synthesis, a review-mining file, transcripts, the CRM
export's closed-won notes. At least one with customer language in it.

## Method

1. Pull every statement of the form "when {situation}, I want {outcome}, so
   I can {result}" from the inputs, in the customer's words, with the
   source. Do not write any yourself.
2. Cluster statements with the same outcome. Each cluster is a job. Name it
   in the customer's verb ("get the weekly report out without the
   spreadsheet"), not the product's noun.
3. For each job, record: the situation that triggers it, the outcome, the
   current alternative (spreadsheet, intern, competitor), how often it
   appears in the inputs, and which page or section should speak to it.
4. Write `research/{YYYY-MM-DD}-jtbd-map.md`: the table, ranked by count,
   then one line per job on the headline it implies, then **Jobs the site
   ignores**: jobs in the data with no page that speaks to them.

## Rules

- Every job cites at least one source line; a job with none is a guess and
  is left out.
- Jobs are outcomes, not features. "Integrates with Slack" is not a job;
  "know when a deal stalls without checking" is.
