---
name: setup
title: Agency setup
description: Set up the agency in HQ from the chat. Build an agency brain, a brain for each current client, and connect the agency's tools, learning from their tools and documents first and asking only what is left open. Ends with a summary of what was set up.
---

# Agency setup

This is a brief, not a script. It says what to build, what you can use and
what good looks like. How you run the conversation is your call: follow the
person's lead, skip what you already know, and keep it quick.

## What to build

1. **An agency brain** in `companies/{firm}/knowledge/agency-playbook/`: who
   they are, what they sell and how they price it, who they sell to, how they
   sound, the tools they run, and their own SOPs.
2. **A brain for each current client**, one home per client under
   `companies/{firm}/clients/{slug}/`: who the client is, what the agency does
   for them, contacts, contract terms, recent activity and where their things
   live, each fact with its source.
3. **Their systems connected**: the agency's tools connected to HQ and linked
   to the client-service slots, and each client's systems noted in that
   client's home.

Good looks like: the person answered a handful of questions, most of the
playbook and client profiles came from their own tools and documents, and at
the end they can see exactly what was set up and where.

## Where you start

Resolve `{firm}` as your worker instructions say, and read the company's
display name from `companies/manifest.yaml`. The app may already have asked
for the agency name; if your turn starts with a `[Pack setup: ...]` note, the
person's message answers it. If the playbook already exists, setup ran before:
say so, and carry on with whatever is missing (often the clients).

After the name, learn their tools before asking about the business: a short
question about where their docs, client chat, CRM and projects live, asked by
kind (docs, team chat, CRM) rather than by brand until they name one. Then
offer to connect the ones that can be read, and read them before asking the
topics below.

## What you need to know about the agency

The topics in the Pack setup section of your instructions (name, services,
ideal client, pricing, tools, voice) each have a goal. A topic is done when
you know what its goal asks for, from the data or from them. A vague answer
("variable pricing", "a mix", "it depends") needs a follow-up on what it
depends on and a typical range; a clear one does not. Propose what you found
in their tools and documents and let them correct it, instead of asking what
the data already says.

## Their tools

How each tool connects and is read is listed in the Pack setup section; rely
on it. Today that means:

- **Google Drive** connects through Google's own sign-in on this Mac
  (`scripts/drive.mjs`): `connect` opens a Google sign-in page in their browser
  (and installs Google's sign-in tool the first time, which takes about a
  minute), `status` confirms it, and `search`, `recent` and `read` read Drive.
  Google lists Drive alongside some Google Cloud permissions on that page;
  that is normal for this sign-in, and you only ever read.
- **Slack** connects through HQ's Personal Slack account (`scripts/slack.mjs`):
  `connect-link` gives the HQ page where they add Slack (Add, then Slack, pick
  the company, allow in Slack), `status` confirms it, and `channels`, `search`,
  `history` and `thread` read it. Slack only lets HQ read channel history
  slowly for now, so search first and open only a few conversations.
- **Email, HubSpot, Salesforce and Teams** are not available yet. Say so
  once if it comes up, plainly, and move on.
- **Other tools** connect with an HQ sign-in link from
  `hq integrations connect <domain> --company {firm} --link-only`.

Ask before you read, and read only what you said you would, with read-only
commands. Useful reads: Drive for proposals, SOPs, pricing, rate cards and
onboarding docs (the best 5 to 10, not everything); Slack search for client
conversations, and `from:me` for how they write to clients; client channel
names to find who their clients are. They can also drop files into the chat.
Describe what you found in your own words; never paste private messages back.

## Writing the agency brain

When you know enough, write the playbook with each topic as a full sentence
the playbook can use (leave out the flag of a topic they skipped; the script
writes a marked placeholder):

```bash
bash core/packages/hq-pack-agency-kit/scripts/agency-setup.sh \
  --firm {firm} --name "{agency_name}" \
  --services "{services}" --ideal-client "{ideal_client}" \
  --pricing "{pricing}" --tools "{tools}" --voice "{voice}"
```

Then add what those sentences cannot hold: a "From their tools and documents"
section in `agency-profile.md` with specifics (price points, packages,
minimums, contract terms) and their sources, and a short markdown copy of
each SOP you found in `knowledge/agency-playbook/sops/{slug}.md`, with its
source at the top.

## Linking their systems

Link the client-service slots to the tools they use (crm, billing,
agreements, portal, transcripts), only where you have evidence, as
`<slot>=<Tool name>:cli`:

```bash
bash core/packages/hq-pack-agency-kit/scripts/firm-setup.sh \
  --firm {firm} --agency-name "{agency_name}" --bind crm=Pipedrive:cli
```

Slots without evidence stay undecided. If it reports `E_ENV_YQ_MISSING`, note
it for the summary; client homes cannot be created until it runs.

## A brain for each client

Work out their current clients from what you read (client Slack channels,
recent proposals and contracts in Drive, deals in a connected CRM) and let
them confirm or edit the list. If you found none, ask them to name their
clients. Write the confirmed list to a file in your memory folder, one per
line as `{slug}<TAB>{Client Name}`, and create every home in one go:

```bash
bash core/packages/hq-pack-agency-kit/scripts/import-clients.sh \
  --firm {firm} --file <that file> --agency-name "{agency_name}"
```

Then fill each client's `client-profile.md` and `access-and-assets.md` from
what you already read, every fact with its source, blank where you have
nothing. Systems are names only; never copy a credential.

## Finishing

Tell them what you set up: the playbook and SOPs, the client homes, what you
connected and linked, and anything not done, each with where to find it in
Files. Offer a next step that fits, such as onboarding their newest client
(`skills/onboarding.md`, gathering that client's documents from their tools
first). Record `Setup: finished` and the date in your progress note.

Only if they have no clients at all, offer a practice run on Northwind Labs,
a made-up client with problems hidden in its documents, loaded with
`scripts/practice-setup.sh --firm {firm} --agency-name "{agency_name}"`.

When something fails, say plainly what did not work and offer to try again
or move on; list anything skipped in the summary.
