---
name: reddit-scout
description: Find founders asking for feedback on their website on Reddit, draft a specific, kind teardown, and build an improved version of one section in the founder's own brand, published to a private link, then draft the short reply a person posts. Keeps a tracker of every teardown and its outcome. A growth workflow for agencies that do web and conversion work. Reads only; a person posts the reply. Use for "find leads on Reddit", "reddit teardown", "scout reddit", "update the Reddit tracker", "log a call with {site}".
triggers:
  - reddit
  - find leads on reddit
  - teardown
  - roast my landing page
  - update the reddit tracker
  - log a call with
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
   from this agency already (`growth/reddit/tracker.md`).
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
Reddit account, and the tracker records the date they say they posted.

## Step 5: The reply → `growth/reddit/{YYYY-MM-DD}-{site}/reply.md`

Once the section is published, draft the reply the person will post under
the founder's post. Short: under 150 words. It answers the founder's
question with two or three specific observations taken from the teardown
(the quote, why it costs them, what to do instead, each in one or two
lines), offers the preview link as a version of the hero they can take, and
names the agency once, plainly, as who wrote it. No pitch, no offer of a
call, no promise of results, nothing the teardown does not say. Save it, show
it, and stop: the person posts it from their own account, or asks for a
rewrite.

## Step 6: The tracker → `growth/reddit/tracker.md`

One file for the whole program, created on the first teardown. At the top,
one line: `Qualified calls booked: {n}`, the count of rows whose status is
`call booked`. Then one table with one row per teardown: date, subreddit,
post (title, linked), site, status, review link. Statuses, in order:
`drafted`, `posted`, `replied`, `call booked`, `not qualified`.

- A new teardown adds a row as `drafted` the moment the reply is saved.
- "I posted it" moves the row to `posted` and records the date.
- "update the Reddit tracker" or "log a call with {site}" finds the row by
  site (or by post link) and sets the status the person names: `replied`
  when the founder answered, `call booked` when a call is on the calendar
  (recount the line at the top), `not qualified` when it will not go
  further. Ask once for the status when the message does not say it.
- Nothing is removed. A row is only ever moved forward.

`growth/reddit/log.md` is kept for older entries; the tracker is the record.

## Rules

- Read only. This workflow never posts, comments, votes, follows or messages.
- One teardown per founder. Check the tracker first.
- Disclose the agency in the teardown; never post from a client's account.
- Nothing invented: no numbers, no claims about results.
