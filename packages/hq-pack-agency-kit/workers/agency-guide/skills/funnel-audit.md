---
name: funnel-audit
title: Run the conversion audit from the chat
description: Run the pack's funnel-audit workflow on one client from the chat. Gathers the client's inputs and transcripts from the workspace, scores the funnel against the playbook's audit criteria with the evidence quoted, ranks the top five experiments, publishes a password-protected review page for the team, revises on comments, and logs the approval.
---

# Run the conversion audit from the chat

The pack's `skills/funnel-audit/SKILL.md` (in your context) is the method:
what to read, what the audit holds, the rules. This file is how you run it in
the chat. Triggers: "run the conversion audit for {Client}", "funnel audit
for {Client}", "audit {Client}", "conversion audit".

## Gathering

1. Resolve the client as `skills/clients.md` does.
2. Read the audit criteria from the playbook. If there are none, say the
   playbook has no audit criteria yet and offer
   ["Write them from my handbook","I'll add them"]; stop there.
3. Read the client's inputs from the workspace (the documents onboarding
   copied from their tools) and the transcripts if there are any, and fetch
   the current site, as SKILL.md Step 0 says. Then one message: what you
   found (brand guide, product details, competitors, proposal or SOW, CRM
   export, analytics export, transcripts with their dates, the site's
   pages), where it came from, and what is missing. The CRM export, the
   analytics export and the site are required; for anything else, say what
   it would add and go on without it. Offer
   ["Use these","Not the right ones"].
4. If a `funnel-audit/{date}-audit.md` exists with `status: draft`, offer to
   carry it on; with `status: approved`, say it is approved and offer a new
   audit or the next step. Never rewrite an approved file.

## Draft

Say in one line that you are scoring the audit, then write the whole audit
in one go: every criterion with its evidence, severity and recommended test,
then the top five experiments, as SKILL.md Step 1 says. No progress notes.

Then one message: the three-line summary (who buys, the biggest leak, the
one change), the scores in one line each ("Message match 1 of 5: the hero
speaks to engineers; 31 of 34 closed-won buyers are ops titles, CRM export
rows 2 to 35"), the top experiment with its evidence, and that every finding
in the file cites its source. "It's in Files, under Clients, {Client},
funnel-audit." Then ["Publish for the team to review","Needs changes"].

## Review

**Publish.** Publishing puts the page on the web behind a password. On
"Publish for the team to review", render the review page and deploy it with
HQ's deploy skill (password access, comments on), reply with the link and
the password, and say it is a draft for the team to review and that nothing
goes to the client. Record the link in the audit file. Then
["Approve the audit","Needs changes"].

**Needs changes, or comments on the page.** Take one message of corrections,
or read the open comments on the review page (the deploy skill's owner
comment routes; when the person says "there are comments" or "check the
comments", read them without asking). Revise the audit, record the changes
under `## Revisions ({date})`, keep `status: draft`, re-render and redeploy
to the same link, resolve each comment you addressed, and reply with
what changed, one line per change, and which comments are still open. Then
["Approve the audit","Needs changes"] again.

**Approve.** Set `status: approved` with the person's name (from `hq whoami`)
and the date in the file, and record it in `engagement.md` as SKILL.md
Step 3 says. Say it is approved and logged, in one line. Then offer the next
step: "The top experiment is {hypothesis, on the {page}}. Want a Page Sprint
proposal built from it?" with
["Draft the Page Sprint proposal","Rebuild that page","Later"].
"Draft the Page Sprint proposal" runs the pack's `proposal` skill with the
experiment as the scope, saved under the client's reports; "Rebuild that
page" runs `skills/site-build.md` on that page.

## Rules that never bend here

- Nothing is sent to the client. The review link is for the team.
- Never show a command, a path or a file's raw contents; the summary and
  the scores are shown because the person needs them to approve.
- Every finding quotes its data and names its source; a finding without one
  is left out. Never invent a number.
- Never mark the audit approved without an "Approve the audit" from the
  person in this chat.
