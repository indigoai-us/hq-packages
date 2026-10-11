---
name: setup
title: Agency setup
description: Set up the agency in HQ from the chat. Build the agency brain (profile, pricing, voice, SOPs), a brain for each current client, and connect the agency's systems, learning from connected apps and documents first and asking only what the data leaves open. Ends with a summary of what was set up.
---

# Agency setup

The goal: when setup ends, the agency owner has

1. **An agency brain**: who they are, what they sell and how they price it,
   how they sound, and their own SOPs, in
   `companies/{firm}/knowledge/agency-playbook/`.
2. **A brain for each current client**: one home per client under
   `companies/{firm}/clients/{slug}/` with what the agency does for them, who
   the contacts are, the contract terms, recent activity, and where their
   things live.
3. **Their systems connected**: the agency's tools linked to HQ (CRM, email,
   Slack, project management, billing), and each client's systems noted in
   that client's home.

Do it fast. Learn from data before you ask. Every question you can answer from
a connected app or a document is a question you do not ask. Keep each message
short, one question or one decision per message, always with buttons.

Before you start, resolve `{firm}` as the worker instructions say, and read the
company's display name from `companies/manifest.yaml` (`companies.{firm}.name`).
Record both in your progress note. If the app already sent the first question
(your turn starts with a `[Pack setup: ...]` note), do not repeat the checks or
the question: the person's message is their answer.

If `companies/{firm}/knowledge/agency-playbook/` already exists, setup has run
before. Say so in one line, offer ["Add my clients","Set up my agency again"],
and carry on from the first stage that is not done.

Record each stage in your progress note as it finishes.

## Stage 1: the name

**1. agency_name** (not skippable). Goal: the name clients know them by.
Propose the company's display name and ask to confirm it; do not ask from
scratch. A name is required; if they try to skip, say one line about why (it
goes on every brief and client update) and ask again.

## Stage 2: your tools

A short interview, then connect. Right after the name, run
`hq integrations list --usable --json --company {firm}` and note what is
already connected. Name tools by what they are for (your email, your CRM),
never by a brand they have not told you they use.

**The interview.** One line per message, one tap per answer, in this order,
skipping any kind already connected:

> What do you use for email?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Gmail","Outlook","Something else","None"]}]}
```

Then the same for "your CRM" (["HubSpot","Salesforce","Pipedrive","Close","Something else","None"]),
"team chat" (["Slack","Teams","Something else","None"]), "where your docs
and SOPs live" (["Google Drive","Notion","Dropbox","Something else","None"])
and "project management" (["Asana","ClickUp","Monday","Something else","None"]).
For "Something else", ask its name in one line. Acknowledge each answer in a
couple of words at the top of the next question. These answers are the
`tools` topic; record them.

**Connect.** Then connect what they picked, one tool per message, most useful
first (email, then CRM, then docs, then chat, then project management):

> Let's connect your Gmail so I can read the emails you've sent clients. Sign in here: {link}

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Done","Skip"]}]}
```

Get the link with `hq integrations connect <domain> --company {firm} --no-browser`,
using the domain in package.yaml `setup.sources` (Gmail `gmail.com`, Outlook
and Teams `graph.microsoft.com`, HubSpot `hubspot.com`, Salesforce
`salesforce.com`, Pipedrive `pipedrive.com`, Close `close.com`, Slack
`slack.com`, Google Drive `drive.google.com`, Notion `notion.so`, Dropbox
`dropbox.com`, Asana `asana.com`, ClickUp `clickup.com`, Monday `monday.com`).
For "Something else", look it up with `hq integrations catalog <name> --company {firm}`.
After "Done", check the list again. If a tool shows an error instead of
connected, or HQ cannot connect it yet, say so in one line and go to the next.

**Read.** Once something useful is connected, say in one line what you will
read and ask for a yes:

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Go ahead","Just ask me"]}]}
```

Read with `hq integrations tools` and `hq integrations call`, using
read-only tools only. Never send, post, label or change anything. Read only what you said:
recent emails sent to clients, recent CRM deals and companies, recent
messages in client channels, SOP and process docs, proposals, rate cards,
active projects. They can also drop files into the chat at any point; read
those too.

While you read, collect three things at once: what the agency is (the topics
below), how its tools should be linked (Stage 4), and who its current clients
are (Stage 5). One read, three uses.

## Stage 3: the agency brain

Send one message proposing an answer for every topic the data covers, one line
each, saying where it came from ("Pricing: retainer from $4k plus 10% of spend
over $40k, from your proposals to Acme and Brightside"). Ask them to confirm or
correct it:

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Looks right","Some of it's off"]}]}
```

Then ask only the topics the data left open, in this order. A topic is done
when you know what its goal says, not when they have replied. "Variable
pricing", "a mix", "it depends" and "Something else" always get a follow-up,
with likely answers as buttons. At most two follow-ups per topic. Never paste
private message text back; describe what you found in your own words.

**2. services**. Goal: what they sell and, per service, what the client
actually gets, enough to tell in-scope from out-of-scope work.
Buttons: ["Paid ads","SEO and content","Web and design","Automations and AI","Something else","Skip"].

**3. ideal_client**. Goal: who they do their best work for: industry, size or
spend, stage. Buttons: ["Ecommerce brands","B2B SaaS","Local businesses","Professional services","Skip"].

**4. pricing**. Goal: how a price is built: the model, what it varies with,
typical ranges or minimums. Buttons: ["Monthly retainer","Per project","Performance based","A mix","Skip"].
A vague answer always gets a follow-up on what it depends on
(["Ad spend","Scope of work","Results","Number of channels"]), then one line
for a typical range or minimum.

**5. tools**. Goal: the tools they run, by kind. You already have this from
the Stage 2 interview; do not ask again.

**6. voice**. Goal: how they sound with clients, specific enough to write in.
Sent emails and proposals are the best source; propose what you heard.

Each topic goes into your note as a full sentence the playbook can use. Then
write the agency brain, saying one line first ("Writing your agency playbook
now."):

```bash
bash core/packages/hq-pack-agency-kit/scripts/agency-setup.sh \
  --firm {firm} --name "{agency_name}" \
  --services "{services}" --ideal-client "{ideal_client}" \
  --pricing "{pricing}" --tools "{tools}" --voice "{voice}"
```

Leave out the flag of a skipped topic; the script writes a marked placeholder.
Then add what the six sentences cannot hold:

- In `agency-profile.md`, a "From their apps and documents" section with the
  specifics (price points, packages, minimums, contract terms), each with its
  source.
- Their SOPs: for each SOP or process doc you found or they dropped in, write
  a short markdown copy to
  `companies/{firm}/knowledge/agency-playbook/sops/{slug}.md` with a title, the
  steps, and the source at the top. Fold anything that changes how they
  onboard clients into `onboarding-checklist.md`, marked with its source.

## Stage 4: link the agency's systems

Link the client-service slots to the tools they use. For each slot you have
evidence for, pass a `--bind`: `crm`, `billing`, `agreements`, `portal`,
`transcripts`, as `<slot>=<Tool name>:cli` for a tool reached through HQ
integrations, for example `--bind crm=HubSpot:cli`.

```bash
bash core/packages/hq-pack-agency-kit/scripts/firm-setup.sh \
  --firm {firm} --agency-name "{agency_name}" --bind crm=HubSpot:cli
```

Slots you have no evidence for stay undecided; do not ask about them now. If
the script says `E_ENV_YQ_MISSING`, record it and list it as not done in the
summary; client homes cannot be created until it runs, so say that too.

## Stage 5: a brain for each client

Propose their current clients from what you read: companies on recent won or
active HubSpot deals, client Slack channels, and the domains they email most
as an agency. One line per client with where you saw them. Up to 15; say if
there are more.

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Add all of them","Let me edit the list","Not now"]}]}
```

If you found none, ask once: "Who are your current clients? Type their names,
one per line." With no data and no names, go to the summary and offer the
practice client at the end (see "No clients yet").

Write the confirmed list to a file in your memory folder, one client per line,
`{slug}<TAB>{Client Name}` (slug: lowercase letters, digits and hyphens), and
create every client home in one go:

```bash
bash core/packages/hq-pack-agency-kit/scripts/import-clients.sh \
  --firm {firm} --file <that file> --agency-name "{agency_name}"
```

Then fill each client's brain from what you already read, without asking the
person anything: in `companies/{firm}/clients/{slug}/client-profile.md`, the
"Who they are", "Why they hired us" and "How they want to work" lines you
have evidence for, each with its source, and blank where you have none. In
`access-and-assets.md`, the client's systems you saw (their ad accounts,
analytics, site platform, shared drives, Slack channel), names only. Never
copy credentials, and never paste message text. Do the clients one after
another; do not message the person per client.

## The done message and summary

Send the done message from `setup.done`, then in the same message a short
summary of what actually happened, for example:

> Your agency is set up in HQ. Here's what I set up:
>
> - Agency brain: your playbook (profile, pricing, voice, scope rules, onboarding checklist) and 3 SOPs, in Files under Knowledge, Agency Playbook.
> - 8 clients, each with a profile filled from HubSpot and Gmail, in Files under Clients.
> - Linked: HubSpot as your CRM. Gmail and Slack are connected for reading.
> - Not done: billing and contracts aren't linked yet.

End with the done suggestion and up to two next steps that fit, for example
the newest client: ["Onboard a client","Onboard {newest client}","Weekly update for {client}"].
Write `Setup: finished` and the date in your progress note.

"Onboard a client" means: ask which client (their names as buttons, newest
first), then run `skills/onboarding.md` for that client, gathering its contract,
proposal, call notes and exports from their apps first and asking for
anything missing.

## No clients yet

Only when there is no client data and they named no clients: after the
summary, offer a practice run.

> No clients in HQ yet. Want to see how onboarding works on a practice client first? Northwind Labs is a made-up company with a few problems hidden in its documents; it takes about 10 minutes.

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Try the practice client","Not now"]}]}
```

On yes, load it, then run `skills/onboarding.md` for `practice-northwind`:

```bash
bash core/packages/hq-pack-agency-kit/scripts/practice-setup.sh \
  --firm {firm} --agency-name "{agency_name}"
```

## When a step fails

Say in one plain sentence what you were doing and that it did not finish
("I couldn't create the client homes yet."), and offer ["Retry","Skip this for now"].
Never show the error text. On Retry, run the same step again. On Skip, record
it and continue; the summary lists it under "Not done".
