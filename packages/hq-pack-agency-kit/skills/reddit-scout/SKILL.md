---
name: reddit-scout
description: Find founders asking for feedback on their website on Reddit, draft a specific, kind teardown, and build an improved version of one section in the founder's own brand, published to a private link. A growth workflow for agencies that do web and conversion work. Reads only; a person posts the reply. Use for "find leads on Reddit", "reddit teardown", "scout reddit".
triggers:
  - reddit
  - find leads on reddit
  - teardown
  - roast my landing page
maturity: HQ-native (authored for this package)
---

# /reddit-scout

Founders post on Reddit asking for feedback on their landing pages. A good
teardown, with one rebuilt section as a gift, is the agency's most credible
first contact. This workflow finds the posts, writes the teardown, builds the
section, and stops: a person reads it, decides, and posts it from their own
account.

## Reading Reddit

`scripts/reddit.mjs` (in the pack) reads Reddit without ever writing to it:

- `node scripts/reddit.mjs status --company {firm}`: which route is in use.
- `node scripts/reddit.mjs search <query> --sub SaaS,startups --days 30 --limit 20 --company {firm}`
- `node scripts/reddit.mjs post <url> --company {firm}`: the post and its top comments.

Two routes. With a free Reddit app registered by the agency (id and secret in
the agency's vault as `REDDIT_CLIENT_ID` and `REDDIT_CLIENT_SECRET`, added
through an HQ secrets link, never pasted into chat), reads use Reddit's API
and are dependable. Without one, reads use Reddit's public feeds, which allow
a few requests before rate-limiting; the script caches the last good result
and returns it when Reddit refuses. Say which route was used.

## Step 1: Find candidates → `growth/reddit/{YYYY-MM-DD}-candidates.md`

1. Read the playbook's Reddit teardown SOP if there is one (which subreddits,
   what a good teardown contains, the agency's rules). Otherwise use
   r/SaaS, r/startups, r/Entrepreneur, r/webdev and r/SideProject, and the
   rules below.
2. Search for feedback requests in the last 30 days. Useful queries: "landing
   page feedback", "roast my landing page", "feedback on my website", "would
   you sign up". Keep posts that (a) link a real site or name it, (b) ask for
   feedback on the site itself, (c) are from the founder or team, (d) match
   the agency's ideal client (from the playbook), and (e) have no teardown
   from this agency already (`growth/reddit/log.md`).
3. Write the top three to five with: post title and link, the site, the
   subreddit, when, why it fits, and one line on what you would say.

**Approval gate 1.** The person picks one, or says none fit.

## Step 2: Read the founder's site

Fetch the site's home page and one more (pricing or product) the way
`site-build` does. Note its brand (colors as hex, fonts, logo address, tone)
so the rebuilt section looks like theirs, not the agency's. Read the post's
comments too; do not repeat what others already said.

## Step 3: Teardown → `growth/reddit/{YYYY-MM-DD}-{site}/teardown.md`

Five to seven findings, specific to this page, each: what you saw (quote),
why it costs them sign-ups (tie it to a conversion principle from the audit
criteria), what to do instead (one concrete change). Kind, direct, no
jargon, no pitch. End with one line that says who you are and that the
rebuilt section below is theirs to use. Never promise results. Never mention
other clients by name.

## Step 4: One rebuilt section → `growth/reddit/{YYYY-MM-DD}-{site}/section/index.html`

Usually the hero: headline, subline, one primary action, one line of proof
if their page has any. In their brand (colors, fonts, their logo linked from
their site). Self-contained HTML with inline CSS, readable on a phone. Then
publish it with HQ's deploy skill behind a password, after asking, and add
the link to the teardown as "a version of your hero you can take".

**Approval gate 2.** The person approves the teardown and the section, or
asks for changes. Approved means saved; posting is theirs, from their own
Reddit account, and the log records the date they say they posted.

## Step 5: Log

Append a line to `growth/reddit/log.md`: date, post link, site, status
(drafted, posted, replied, became a lead), and the review link.

## Rules

- Read only. This workflow never posts, comments, votes, follows or messages.
- One teardown per founder. Check the log first.
- Disclose the agency in the teardown; never post from a client's account.
- Nothing invented: no numbers, no claims about results.
