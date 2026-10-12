---
name: onboarding
title: Client onboarding in chat
description: Run the Agency Kit's onboarding system on one client from the chat, one step at a time with an approval gate per step. Same step order and same files as the pack's /client-onboarding skill.
---

# Client onboarding in chat

The pack's `skills/client-onboarding/SKILL.md` (in your context) is the full
method: what to read, what each file contains, and the rules (the contract
wins; quote or cite; never fill a gap with an estimate). This skill is how you
run it in the chat. Follow the SKILL.md for the content of each file and this
file for the conversation.

Inputs: `{firm}` (the worker instructions say how) and `{slug}`, the client.
For the practice client, `{slug}` is `practice-northwind` and the client's
name is Northwind Labs. For a real client, `skills/clients.md` resolves the
slug and sends you here.

## Before step 1

1. Read every file in `companies/{firm}/knowledge/agency-playbook/`.
2. Gather the documents from their tools first, as SKILL.md Step 0 says.
   Check every kind of source, not the first one that answers:
   - docs (Google Drive, Notion, Dropbox, an e-signature tool) for the
     contract, SOW and proposal;
   - the notetaker for the full transcript of every call with the client,
     and the docs tools too: many notetakers sync transcripts into a Drive
     or Notion folder (search for the client's name with "transcript",
     "call" or "meeting");
   - the CRM for the deal, its contacts and any attached files.
   If no docs tool is connected, say so and offer to connect Google Drive or
   Notion (or whatever they keep documents in) right then, with
   ["Connect Google Drive","Connect Notion","I'll add the files"]; contracts
   usually live there. Then show what you found, saying which sources you
   checked and where each document came from, and offer
   ["Use these","Not the right ones"]. Ask only for what you could not find,
   as a Files location ("Files, under Clients, {Client}, onboarding, inputs")
   or pasted text.
   A missing signed contract never ends the run. Say which signed document
   you will treat as the agreement instead (a signed proposal or order form,
   else the CRM deal), offer ["Go ahead with that","I'll find the contract"],
   and on "Go ahead" start step 1 with "No signed contract found" as a
   blocking open question in the brief. Never offer to remove the client.
3. If `onboarding/status.md` exists, this is a re-run. Read its Steps table
   and resume at the first step that is not approved. Never rewrite an
   approved file.
4. For Northwind, say in one line that this is the practice client with
   invented data and that they are the strategist: their job is to push back
   on anything that looks wrong.

Write `companies/{firm}/clients/{slug}/onboarding/status.md` with the Steps
table (from SKILL.md, Step 2) before step 1 if it does not exist.

## The four steps

Each step: do the work from SKILL.md, write the file, update the Steps table,
then send one gate message. Never send two steps in one message, and never
start the next step before the gate is approved.

| Step | Writes | SKILL.md section |
|---|---|---|
| 1 Scope review | `01-client-brief.md` | Step 1 |
| 2 Missing inputs | `02-intake-request.md` and `status.md` Inputs | Step 2 |
| 3 Account audit | `03-audit.md` | Step 3 |
| 4 Kickoff package | `04-kickoff-package.md` | Step 4 |

Every numbered file starts with the front matter from SKILL.md:

```yaml
---
client: {slug}
step: 1
status: draft
approved_by:
approved_at:
---
```

### The gate message

Exactly this shape, every time:

1. A two-line summary of the file. Line one: what it found. Line two: what
   that means or what is open. For the brief (step 1), line one lists the
   mismatches found, each with its source in a few words ("call vs contract:
   Edge and Academy discussed, contract covers Cloud only"), and line two
   gives the open-questions count and how many are blocking. For the audit
   (step 3), line one is the headline finding with its number and source.
   For the intake request (step 2), say plainly that it is a draft and nothing
   has been sent.
2. The file's location, as a Files location: "It's in Files, under Clients,
   {Client}, onboarding, {file name}."
3. The approval block:

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Approve","Needs changes"]}]}
```

Do not paste the file into the chat. The summary is the summary; the file is
in Files.

### Approve

1. Get the person's display name from `hq whoami` (never ask for it) and
   today's date.
2. In the file, set `status: approved`, `approved_by: {Display Name}`,
   `approved_at: {YYYY-MM-DD}`.
3. In `status.md`, set that step's row to `approved`, with the name and date.
4. Record the gate in your progress note.
5. Start the next step in the same turn and end with its gate message.

### Needs changes

1. Ask for the corrections in one message: "What should change? One message
   is enough; I'll record it." No suggestions block.
2. When their message arrives, add a `## Corrections ({YYYY-MM-DD})` section
   at the end of the file with their message, make the change in the file's
   body where you can, keep `status: draft`, and set the Steps row to
   `draft, corrections recorded`.
3. If they caught something the playbook should have caught, note it in your
   progress note for the learnings step.
4. Stop. Say in one line that the correction is recorded, and offer
   ["Approve","Needs changes"] again for the same step. The next step does
   not start until this gate is approved.

## After the kickoff package is approved

Do steps 5 and 6 from SKILL.md without a gate:

- Step 5: add the Timeline line, the Awaiting client items and the Decisions
  to `companies/{firm}/clients/{slug}/engagement.md`, as SKILL.md says.
- Step 6: ask one question, "Did you catch anything this process should have
  caught on its own?", with ["No, it got everything","Yes, one thing"]. Add
  each lesson (theirs, plus every correction from the gates) as a row in
  `knowledge/agency-playbook/learnings.md`, and propose the matching playbook
  line (checklist, audit criterion or scope rule) in one sentence with
  ["Add it","Leave the playbook as is"]. Write it only on "Add it".

For Northwind, then grade the run:

```bash
bash core/packages/hq-pack-agency-kit/scripts/grade-practice.sh --firm {firm}
```

Tell them in a short list which of the eight planted problems the run caught
and which it missed, in plain words (the script prints the names). For each
one missed, say which playbook line would have caught it and offer to add it,
same as Step 6.

Then close with how to start a real client, in two sentences and no commands:

> That's the whole onboarding system, and it will run the same way on your real clients. When one signs, tell me "new client" and their name, and I'll set up their folder and tell you where to drop their documents.

No suggestions block on that message unless a real client is already waiting.

## Rules that never bend here

- Nothing is sent to anyone. The intake request is a draft the person sends
  themselves; say so at its gate. You never email, message or post.
- You never ask the person to open a terminal, Claude Code, or a file on
  disk. The file is in Files; the summary is in the chat.
- Every finding cites its source. If you cannot point to the line, it does
  not go in the file.
- Never mark a step approved without an "Approve" from the person in this
  conversation.
