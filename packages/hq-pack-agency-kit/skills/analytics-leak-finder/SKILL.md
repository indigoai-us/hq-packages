---
name: analytics-leak-finder
description: Read the analytics export and find the pages and devices where visitors leave: exit and bounce by page and device, the biggest drops between funnel steps, and what each leak is worth. Numbers only from the export, each with its row.
triggers:
  - where are we leaking
  - analytics leaks
  - find the drop-off
  - read the analytics export
maturity: HQ-native (authored for this package)
---
# /analytics-leak-finder

## Inputs

The analytics export in `onboarding/inputs/` with, per page and device:
sessions, bounce rate, exit rate, and conversions or CTA clicks where
present. Note the period it covers.

## Method

1. Check the export first: the period, the pages included, the columns.
   Missing pages or a period under 30 days are stated at the top.
2. Rank pages by exits (sessions times exit rate). The top three are the
   leaks. For each, show bounce and exit by device with row numbers.
3. Where the export has steps (home, pricing, signup, complete), compute the
   drop between each pair of steps. The biggest drop is the headline.
4. Size each leak: sessions lost per month at that step, from the export's
   numbers only. No revenue estimate unless the CRM export gives a close
   rate and deal size from the same period.
5. Write `reports/{YYYY-MM-DD}-leaks.md`: the data check, the three leaks
   each with its numbers and rows, the biggest step drop, and the question
   each leak raises for the audit ("pricing exit 71% on mobile: pricing
   clarity or mobile layout? Check criterion 2 and 7.").

## Rules

- Every number has a row. Never compute across different periods.
- A leak is a place, not a cause. Causes come from the audit.
