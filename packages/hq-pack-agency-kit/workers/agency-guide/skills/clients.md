---
name: clients
title: Real clients from the chat
description: The standing-helper flows for real clients. "new client {name}" sets up the workspace; "onboard {client}" runs the stepped onboarding; "is this in scope: {request}" and "weekly update for {client}" post drafts for approval and save them. Nothing is ever sent.
---

# Real clients from the chat

Once the playbook exists you are the agency's standing helper. These are the
four things people come back for. Each one is done by you, in the chat, with
the scripts and skill files in the Agency Kit; the person never sees a command.

## Finding the client

A client is a folder under `companies/{firm}/clients/` (skip `_`-prefixed
folders). Resolve a name to a slug by matching it against the folder names and
the `client-name` lines in each `engagement.md`, case-insensitively, ignoring
punctuation. One match: use it. Several: ask which one, with the matching
client names as suggestions. None: say you do not have a client by that name
and offer ["New client {Name}","Show my clients"]. Never guess.

## "new client {name}"

Also: "we signed {name}", "{name} just signed", "add a client".

1. Make the slug: lowercase, letters, digits and hyphens, from the name
   ("Atlas & Sons" becomes `atlas-sons`). If `companies/{firm}/clients/{slug}/`
   already exists, say so and offer ["Onboard {Name}","Pick another name"].
2. Create the engagement record:

   ```bash
   bash core/packages/hq-pack-client-service/scripts/new-client.sh engagement \
     --firm {firm} --client {slug} --client-name "{Name}" --local-only
   ```

3. Ask the folder-or-company question. Read the playbook default from the
   `Default client workspace:` line in
   `companies/{firm}/knowledge/agency-playbook/agency-profile.md` and put it
   first:

   > Should {Name} live as a folder inside your agency, or get their own HQ company? A folder is the usual choice. Their own company is for clients who will run HQ themselves or take the work with them later.

   ```hq-block
   {"v":1,"blocks":[{"kind":"suggestions","items":["A folder in my agency","Their own HQ company"]}]}
   ```

   (Order the two items so the playbook default is first.) The answer applies
   to this client only.

4. Scaffold the workspace with the chosen mode:

   ```bash
   bash core/packages/hq-pack-agency-kit/scripts/client-workspace.sh \
     --firm {firm} --client {slug} --client-name "{Name}" --mode {folder|company}
   ```

5. Company mode only: the script prints the steps it cannot do itself
   (creating the client's company, adding it to the session, the client-facing
   home). Do not run them from here. Post them as a short checklist in plain
   words, without commands ("Create {Name}'s own company in HQ", "Set up
   their client-facing home", "Invite their team, when you're ready"), and say
   the folder half is complete and usable now. Offer ["Start the checklist","Later"].
   On "Start the checklist", do each item you can with the HQ commands
   available to you, confirming before anything that creates a company or
   invites a person.

6. Close with where things go and what to do next, as Files locations:

   > {Name} is set up. When you kick them off, I'll pull their contract, proposal and call notes from your tools; anything I can't find, you can drop into Files, under Clients, {Name}, onboarding, inputs.

   ```hq-block
   {"v":1,"blocks":[{"kind":"suggestions","items":["Kick off {Name}","Weekly update for {Name}"]}]}
   ```

Record the new client in your memory folder (name, slug, mode, date).

## "onboard {client}"

Also: "kick off {client}", "run onboarding on {client}", "{client} is ready".

1. Resolve the slug.
2. Run `skills/onboarding.md` for `{slug}`. It gathers the documents from
   their tools first (contract and proposal from docs tools and the CRM, full
   call transcripts from the notetaker), shows what it found, and asks only
   for what it could not find. Same four steps, same gates, same files.

## "is this in scope: {request}"

Also: "{client} is asking for {thing}, is that in scope", "scope check".

Follow `core/packages/hq-pack-agency-kit/skills/scope-check/SKILL.md` (in your
context) for how to decide and what to read. In the chat:

1. Resolve the client. If the message names no client and there are several,
   ask which one. If the request text is missing, ask for it in one line.
2. Decide: in scope, out of scope, or unclear, with the clause. If there is no
   contract in `onboarding/inputs/` and no commercials in `engagement.md`,
   look for the contract in their tools first (as onboarding does) and save
   it there. Only if it is nowhere, say you cannot judge scope without it,
   name the inputs location, and stop.
3. Write the draft to
   `companies/{firm}/clients/{slug}/reports/{YYYY-MM-DD}-scope-check.md`:
   the request, the verdict with the clause, and the reply or change-request
   outline in the agency's voice. Front matter as in onboarding
   (`status: draft`, `approved_by`, `approved_at`).
4. Post the verdict in one line with the clause, then the draft reply in full
   (these are short), then the location ("It's in Files, under Clients,
   {Name}, reports"), and say nothing has been sent. End with:

   ```hq-block
   {"v":1,"blocks":[{"kind":"suggestions","items":["Approve","Needs changes"]}]}
   ```

5. Approve: set `status: approved` with the person's name (from `hq whoami`)
   and date in the file, and append the decision line to `engagement.md`
   under Decisions (date, request, verdict, clause). Say it is saved and that
   they send it when they are ready. Needs changes: take one message of
   corrections, record it in the file, keep `status: draft`, stop.

## "weekly update for {client}"

Also: "write the weekly for {client}", "client update for {client}".

Follow `core/packages/hq-pack-agency-kit/skills/weekly-update/SKILL.md` (in
your context) for what to read and the four sections. In the chat:

1. Resolve the client.
2. Ask one question before drafting: "Anything from this week that isn't in
   HQ yet?" with ["No, draft it","Yes, one thing"]. Take their answer.
3. Write the draft (under 250 words, four sections, nothing from the
   engagement's firm-internal section) to
   `companies/{firm}/clients/{slug}/reports/{YYYY-MM-DD}-weekly-update.md`,
   with the same draft front matter.
4. Post the draft in full, the location ("It's in Files, under Clients,
   {Name}, reports"), and that nothing has been sent. End with
   ["Approve","Needs changes"].
5. Approve: set `status: approved`, the person's name and date in the file,
   and add a Timeline line to `engagement.md`: "Weekly update drafted and
   approved." Say it is saved and that they send it from wherever they talk
   to the client. Needs changes: one message of corrections, recorded in the
   file, `status: draft`, stop.

The pack's Claude Code skill saves updates under `updates/`; from the chat
they go under `reports/`, which is the folder the client workspace README
names for weekly updates. Say "reports" to the person either way.

## Never

- Never send, email, post or message anything to a client or anyone else, and
  never offer to. Approved means saved; sending is theirs.
- Never show a command, a path or a file's raw contents when a summary and a
  Files location will do (drafts are the exception: they are short and the
  person needs to read them to approve them).
- Never invent a clause, a number or a result. If you cannot cite it, say
  what is missing instead.
