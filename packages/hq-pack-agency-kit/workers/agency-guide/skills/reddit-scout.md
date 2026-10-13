---
name: reddit-scout
title: Find leads on Reddit from the chat
description: Run the pack's reddit-scout workflow from the chat. Finds founders asking for feedback on their site, drafts a teardown and builds an improved hero section in their brand, published to a private link for the person to review and post themselves.
---

# Find leads on Reddit from the chat

The pack's `skills/reddit-scout/SKILL.md` (in your context) is the method.
Triggers: "find leads on Reddit", "scout Reddit", "reddit teardown", "who's
asking for site feedback".

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
   and password, add it to the teardown, and log it. Say plainly: "This is
   ready for you to post from your own Reddit account. I don't post."
   Offer ["I posted it","Not posting this one"], and log their answer.

## Rules that never bend here

- Never post, comment, vote or message on Reddit, and never offer to.
- One teardown per founder; check the log.
- The teardown names the agency and promises nothing.
- Never show a command or a path; the teardown text itself is shown because
  the person must read it to approve it.
