---
name: reddit-scout
title: Find leads on Reddit from the chat
description: Run the pack's reddit-scout workflow from the chat. Finds founders asking for feedback on their site, drafts a teardown and builds an improved hero section in their brand, published to a private link, drafts the reply the person posts themselves, and keeps the Reddit tracker up to date.
---

# Find leads on Reddit from the chat

The pack's `skills/reddit-scout/SKILL.md` (in your context) is the method.
Triggers: "find leads on Reddit", "scout Reddit", "reddit teardown", "who's
asking for site feedback". Tracker triggers: "update the Reddit tracker",
"log a call with {site}", "{site} replied", "how's Reddit going".

## Flow

1. **Check the route.** Run the script's `status` and say in one line which
   route is in use. If it is the public one, say reads may be rate-limited and
   offer the dependable route once, in plain words: "If you register a free
   Reddit app, I can read Reddit reliably. I'd send you a secure link to paste
   the app's id and secret into HQ; they never go through this chat." Offer
   ["Set that up","Carry on without it"]. On "Set that up", send two HQ
   secrets links (`REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET`, in the
   agency's vault) and the three steps on reddit.com/prefs/apps (create app,
   type "web app", any redirect URL), then carry on when they say done.
2. **Search.** Use the playbook's subreddits and queries, or the defaults.
   Say in one line that you are looking. Then post the candidates: three to
   five, each as the post title (linked), the site, how old, and one line on
   why it fits. Offer them as buttons by site name, plus ["None of these"].
   If Reddit refused and nothing is cached, say so plainly and offer to try
   again in a few minutes or set up the app route.
3. **Teardown and section.** On a pick, read the post and the founder's site,
   write the teardown and build the hero section as SKILL.md says. Then one
   message: the teardown in full (it is short and they have to approve it),
   where it is ("Files, under Growth, Reddit, {date} {site}"), and that the
   hero section is built and can be published to a private link. Offer
   ["Approve and publish the section","Needs changes"].
4. **Publish.** Deploy the section behind a password, reply with the link
   and password, add it to the teardown, and add the row to the tracker as
   `drafted`.
5. **The reply.** Draft the reply as SKILL.md Step 5 says: short, answers
   the founder's question with two or three specific observations from the
   teardown, offers the preview link, names the agency once, no pitch. Show
   the draft in full in the same message, say it is saved next to the
   teardown, and say plainly: "This is ready for you to post from your own
   Reddit account. I don't post." Offer
   ["Looks good, I'll post it","Rewrite it"]. On "Rewrite it", take one
   message of direction, rewrite, show it again, same buttons.
6. **After they post.** On "I posted it" (or "Looks good, I'll post it"
   followed by "posted"), move the row to `posted` with the date, and say
   once: "I'll keep the tracker up to date. When the founder replies, a call
   gets booked, or it goes nowhere, tell me and I'll log it." No buttons;
   the outcome comes later.

## The tracker

On "update the Reddit tracker", "log a call with {site}" or any message
that names a site and an outcome: find the row by site or post, set the
status the message gives (`replied`, `call booked`, `not qualified`), update
the qualified-calls line at the top, and reply in one line with the row's
new status and the count ("Logged: {site}, call booked. Qualified calls
booked: 3."). If the message names the site but not the outcome, ask once
with ["They replied","Call booked","Not qualified"]. If the site is not in
the tracker, say so and offer ["Show the tracker","Start a teardown for it"].
On "how's Reddit going" or "show the tracker", post the count and the rows in
one short table, newest first. "It's in Files, under Growth, Reddit,
tracker."

## Rules that never bend here

- Never post, comment, vote or message on Reddit, and never offer to.
- One teardown per founder; check the tracker.
- The teardown names the agency and promises nothing.
- Never show a command or a path; the teardown and the reply are shown in
  full because the person must read them to approve or post them.
- The reply never pitches, never offers a call and never promises a result.
