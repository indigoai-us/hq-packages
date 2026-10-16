---
name: site-build
title: Rebuild a client's site from the chat
description: Run the pack's site-build workflow on one client from the chat. Gathers the client's data from the agency's tools, writes an evidence brief, builds the site in the client's brand, writes a before/after with a data point per change, and publishes a review link, with an approval gate at each step.
---

# Rebuild a client's site from the chat

The pack's `skills/site-build/SKILL.md` (in your context) is the method:
what to read, what each file holds, the rules. This file is how you run it in
the chat. Triggers: "new site for {client}", "rebuild {client}'s site",
"page sprint for {client}", "build {client} a landing page".

## Before step 1

1. Resolve the client as `skills/clients.md` does.
2. Gather the client's data from their tools first, as SKILL.md Step 0 says,
   and fetch the client's current site. Then one message: which sources you
   checked, what came from each (brand guide, product details, competitors,
   CRM export, analytics, transcripts, the current site's pages), and what is
   missing. The brand guide and the current site are required; for anything
   else that is missing, say what it would add and go on without it. Offer
   ["Use these","Not the right ones"].
3. If `site-build/01-evidence.md` exists with `status: approved`, resume at
   the first step that is not approved. Never rewrite an approved file.

## The steps

| Step | Writes | Gate |
|---|---|---|
| 1 Evidence brief | `01-evidence.md` | the plan |
| 2 Build | `site/` | none (the before/after is the gate) |
| 3 Before and after | `02-before-after.md` | the result |
| 4 Publish | review link | "Publish it" |

Each gate message: a short summary, the Files location, the approval block.

**Gate 1 (the plan).** Lead with who actually buys, in one sentence with its
source ("closed-won deals are operations leads at 50 to 300-person
companies; the site speaks to engineers"). Then the three biggest leaks with
their numbers, and the page list with one line per page on what changes.
Name any open question for the client. "It's in Files, under Clients,
{Client}, site-build, 01-evidence." Then ["Approve the plan","Needs changes"].

**Build.** Say in one line that you are building, then build all pages in
one go and write the before/after. No progress notes about files or
templates. The build can take a few minutes; the app shows you working.

**Gate 2 (the result).** Three or four before/after lines, each with its
data point ("Hero: was 'API-first workflow automation for modern engineering
teams'; now speaks to operations leads, because 31 of 34 closed-won buyers
are ops titles, CRM export rows 2 to 35"). Say every change in the file has
one. "It's in Files, under Clients, {Client}, site-build, 02-before-after,
and the site is in the site folder next to it." Then
["Publish for review","Needs changes"].

**Publish.** Publishing puts the site on the web behind a password. On
"Publish for review", deploy with HQ's deploy skill (password access), reply
with the link and the password for the account lead, and record the link in
the before/after. If they ask to make it public, confirm once ("Public means
anyone with the link can see it. Make it public?") with
["Make it public","Keep it private"], then redeploy public. Nothing is sent
to the client; the account lead shares it.

**Needs changes.** Take one message of corrections, record them in the file
under `## Corrections ({date})`, make the change, keep `status: draft`, and
offer the same gate again. The next step waits.

## After publishing

Record it in `engagement.md` as SKILL.md Step 5 says, then ask once: "Did you
catch anything this process should have caught on its own?" with
["No, it got everything","Yes, one thing"]. Each lesson goes to
`learnings.md`, and with a yes, into the audit criteria or the site-build SOP.
Say what you set up and where, in three lines, and offer what fits next
(a weekly update, a scope check, or another client).

## Rules that never bend here

- Nothing is sent to the client. The review link is for the account lead.
- Never show a command, a path or a file's raw contents.
- Every change cites its data point; a change without one does not go in.
- Never change the client's logo or colors; never invent proof.
