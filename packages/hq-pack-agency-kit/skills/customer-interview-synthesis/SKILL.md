---
name: customer-interview-synthesis
description: "Turn a set of customer interview transcripts into the patterns that matter for conversion work: the jobs people hire the product for, the words they use, the objections they raise, and the moments they decided. Every pattern cites the transcript and timestamp."
triggers:
  - synthesize the interviews
  - what did customers say
  - interview synthesis
  - summarize the customer calls
maturity: HQ-native (authored for this package)
---
# /customer-interview-synthesis

## Inputs

Three or more transcripts, from the client's `onboarding/inputs/transcripts/`
or the notetaker, each with a date and the people on the call. Fewer than
three: say so and synthesize anyway, marked "thin".

## Method

1. Read every transcript in full before writing anything. Note, per
   transcript, with the timestamp: the trigger (what made them look), the
   alternatives they considered, the objection they raised, the words they
   used for the problem and the result, and the moment they decided.
2. Group the notes across transcripts. A pattern needs at least two
   transcripts behind it; a line from one transcript is an example, not a
   pattern, and is labelled as one.
3. Write `research/{YYYY-MM-DD}-interview-synthesis.md`:
   - **Who was interviewed**: title, segment, date, in a table.
   - **Jobs**: each job in the customer's words, with the count of
     transcripts and two quotes with timestamps.
   - **Triggers and alternatives**: what started the search, what else they
     tried.
   - **Objections**: each with its count and a quote.
   - **Their words**: ten phrases to use on the page, verbatim, each with
     its source.
   - **What this changes**: three lines on the page, the headline and the
     proof, each pointing at the pattern behind it.

## Rules

- Quote; never paraphrase into a claim the transcript does not make.
- Count honestly: "3 of 5 calls" not "most customers".
- Never name a customer on a page without their permission being recorded.
