---
name: growth-scout
description: "One-shot Reddit growth run with no questions: find a founder asking for site feedback, write the teardown, build the rebuilt hero on a private link, draft the reply for a person to post, log it in the tracker, and report everything in one message. Never posts to Reddit. Built for scheduled runs and Slack agents."
triggers:
  - run the growth scout
  - growth scout
  - run the reddit scout now
  - daily reddit run
maturity: HQ-native (authored for this package)
---
# /growth-scout

The unattended version of `reddit-scout`. It runs start to finish without
asking anything and ends with one message a person can act on. Use it from a
scheduled job or from a Slack agent. The method, file formats and rules are
those of `skills/reddit-scout/SKILL.md`; this skill only changes how the run
is driven and what the person sees.

## Rules for the whole run

- Ask nothing. Decide every choice yourself with the SOP and the playbook.
- Never post, comment, vote or message on Reddit.
- Never show commands, file paths, cache details, routes, rate limits, tool
  names or error text. The person sees results, not plumbing.
- Keep the final message under 250 words plus the reply draft.

## Steps

1. **Candidates.** Search the SOP's subreddits for founders asking for
   feedback on a landing page, pricing page or site (last 30 days). If a
   search is refused, use whatever came back and the most recent candidates
   already saved under `growth/reddit/`. Skip any site already in
   `growth/reddit/tracker.md`.
2. **Pick one.** Prefer a company product with a live site and a clear offer;
   B2B first, then B2C SaaS. Do not require a pricing page. If no candidate
   has a reachable site, stop and send one line: "No new feedback requests
   worth a teardown today; I'll try again tomorrow."
3. **Teardown.** Read the post and the site. Write the teardown as
   `reddit-scout` describes: three specific findings with the evidence from
   the page, in the agency's voice, naming the agency once, promising nothing.
4. **Hero.** Build the rebuilt hero section in the founder's own brand (their
   colours, fonts and wording where it works), one primary action, one proof
   line if the site has real proof. No invented numbers or testimonials.
5. **Publish.** Deploy the section to a private, password-protected link.
6. **Reply.** Draft the Reddit reply (under 150 words): answer the question
   with two or three observations from the teardown, offer the preview link,
   name the agency once, no pitch.
7. **Log.** Add the tracker row with status `drafted` (date, subreddit, post,
   site, review link).
8. **Report**, one message, in this order: founder and site; the three
   findings as three short lines; the preview link and password; the reply
   draft in full; one closing line: "Post the reply from your own account,
   then tell me 'posted' or 'call booked with {site}' and I'll update the
   tracker."

## Afterwards

"posted", "replied", "call booked with {site}" and "not qualified" move the
tracker row forward and update the qualified-calls count; confirm in one
line.
