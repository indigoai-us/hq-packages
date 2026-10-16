---
name: objection-handling-section
description: "Write the section that answers the objections buyers raise before they ask: security, integrations, migration, price, time to value. Each objection from the CRM lost reasons or transcripts with its count; each answer from the product details only."
triggers:
  - objection handling
  - answer the objections
  - security section copy
  - write the faq section
maturity: HQ-native (authored for this package)
---
# /objection-handling-section

## Method

1. Pull every objection from the CRM lost reasons and the transcripts
   (search for security, SOC 2, SSO, integrates, migrate, switch, price,
   how long, support). Count each. Anything raised more than twice (the
   playbook's threshold) goes in; the rest is listed as "heard once".
2. For each objection, find the true answer in the product details:
   certifications held, integrations shipped, migration help offered,
   support hours. If the product details do not answer it, write "Client to
   confirm" and never guess.
3. Write each as a short block: the objection in the buyer's words (the
   quote, source), the answer in two lines, and the link it points to
   (security page, integrations page, docs).
4. Write `build/{YYYY-MM-DD}-objections-{page}.md`: the ranked blocks, the
   placement (within one click of the home page; reachable from pricing),
   and the items marked "Client to confirm".

## Rules

- Objections come from the data with counts; never from a generic list.
- Answers come from the product details; a certification not listed there
  is not claimed.
- Never name a competitor in an answer.
