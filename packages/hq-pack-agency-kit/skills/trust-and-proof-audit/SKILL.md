---
name: trust-and-proof-audit
description: Count and verify every piece of proof on the client's site (logos, quotes, numbers, certifications) against the CRM export, the product details and the transcripts, and find the proof the client has but does not show.
triggers:
  - trust audit
  - proof audit
  - is the social proof real
  - where's the proof
maturity: HQ-native (authored for this package)
---
# /trust-and-proof-audit

## Method

1. Inventory every proof item on the site: customer logos, named quotes,
   quantified outcomes, certifications, integration badges, press. Quote
   each with the page.
2. Verify each against the data: the customer appears as closed-won in the
   CRM export (row); the number appears in a case study or product
   document; the certification appears in the product details. Mark each
   verified, unverified or contradicted.
3. Match proof to the ICP (from the CRM: the modal closed-won segment).
   Enterprise logos on a mid-market site are a finding; three mid-market
   logos beat one enterprise logo.
4. Find the missing proof: closed-won customers reps name on calls (the
   transcripts, with timestamps) who are not on the site; certifications in
   the product details with no mention; outcomes the client has measured.
5. Write `reports/{YYYY-MM-DD}-proof-audit.md`: the inventory table with
   its verification column, the proof to remove (unverified or
   contradicted), the proof to add with its source, and the permissions
   still needed from each named customer.

## Rules

- Unverified proof is a finding even when it is probably true.
- Never add a customer name to a page without a recorded permission.
- Never invent a number to fill an empty proof slot.
