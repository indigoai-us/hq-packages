---
name: setup
title: Agency setup
description: Set up the agency in HQ from the chat. Build an agency brain, a brain for each current client, and connect the agency's tools, learning from their tools and documents first and asking only what is left open. Ends with a summary of what was set up.
---

# Agency setup

This is a brief, not a script. It says what to build, what you can use and
what good looks like. How you run the conversation is your call: follow the
person's lead, skip what you already know, and keep it quick.

## Why

The point is to get the Agency Kit set up fast, with a workspace configured
for each of their clients, so they can then look through those client
workspaces and run a real workflow on one (onboarding, a scope check or a
weekly update). Speed matters more than completeness: a good-enough setup in
a few minutes beats a thorough one that drags.

Connecting their tools is only a way to get there faster: to find their
clients and fill in details and context about each one without making them
type it. It is not a goal on its own. Connect only what helps with that, read
only what you need, and do not keep connecting or reading once you have
enough to set the clients up.

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
playbook and client profiles came from their own tools and documents, every
current client has a workspace with real context in it, and at the end they
can see exactly what was set up and where, and are one step from opening a
client workspace or running a workflow.

## Where you start

Resolve `{firm}` as your worker instructions say, and read the company's
display name from `companies/manifest.yaml`. The app may already have asked
for the agency name; if your turn starts with a `[Pack setup: ...]` note, the
person's message answers it. If the playbook already exists, setup ran before:
say so, and carry on with whatever is missing (often the clients).

After the name, learn their tools before asking about the business: a short
question about where their docs, client chat, CRM, project management and
meeting notes live, asked by kind (docs, team chat, CRM, project management,
notetaker) rather than by brand until they name one. Then
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

Also ask for their website, unless their documents already give it, in one
short question ("What's your website? Pages I make for clients will match its
look."). Client-facing pages the kit makes, such as a client's kickoff plan,
follow its look. Read the homepage and one more page (about or services) with
a plain web fetch, and note the look: the logo's address, the main colors as
hex codes, the fonts, the overall style (for example "dark, minimal, big
serif headlines") and a few phrases in their voice. If they have no website,
ask for a brand guide or two colors and a font, or skip it.

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
  `connect --company {firm}` opens Slack's own sign-in page in their browser
  (they pick the workspace and press Allow; HQ keeps the sign-in in their
  vault), and `status` confirms it. Always put the link in your message too,
  so they can open it in another browser. Slack only lets a workspace owner
  connect HQ's app until it is listed in Slack's Marketplace: if they are not
  the owner, or the page says HQ "can't be installed" or stays blank, say so
  plainly and offer the workaround (they ask their workspace owner, or paste
  or name their client channels), then move on. For setup, the channel list (`channels`)
  is what you need: from the names, purposes and shared flags you can tell
  who their clients are and which channels belong to each. `history`,
  `thread` and `search` exist, but use them only if the person asks for
  more; search may not be allowed on their connection yet.
- **Any tool they use** is worth trying, not only the ones named here. The
  Pack setup section lists the order to try: HQ's catalog and a sign-in link,
  an access key they enter through an HQ secrets link (never in the chat), a
  docs page or MCP server, then a workaround such as an export dropped into
  the chat. Never say a tool cannot be connected before trying those.
- **Their notetaker and project management tool**: always ask which ones
  they use and offer to connect them, even when you already know the
  clients. They are what make a client workspace useful: the notetaker gives
  each client's recent meetings (what was agreed, what is next) and the
  project tool gives what is in flight, and the workflows draw on both. If
  their transcripts sync into Drive or Notion, that folder is their
  notetaker: connect that tool and read the transcripts there.
  Fireflies, Fathom, Granola, Otter, Read AI and Grain (notetakers) and
  ClickUp, Monday and Linear (projects) connect with an HQ sign-in link;
  Asana with a personal access token through an HQ secrets link.
- **Email and Teams** have no direct connection yet. Offer the workaround
  (a few forwarded or pasted emails, or the client channel names) once, and
  move on.
- **Other tools** connect with an HQ sign-in link from
  `hq integrations connect <domain> --company {firm} --link-only`. Read them
  with `hq integrations tools --company {firm}` to see what they offer, then
  `hq integrations call` with read-only tools only.

Ask before you read, and read only what you said you would, with read-only
commands. Useful reads: Drive for proposals, SOPs, pricing, rate cards and
onboarding docs (the best 5 to 10, not everything); the Slack channel list
to find who their clients are; the notetaker and project tool for the
confirmed clients only (each client's last few meetings and open projects,
not their whole history). They can also drop files into the chat.
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
source at the top. Write what you noted about their website to
`knowledge/agency-playbook/brand.md` (website address, logo address, colors,
fonts, style, voice phrases), with the pages you read as its source.

## Linking their systems

Link the client-service slots to the tools they use (crm, billing,
agreements, portal, transcripts), only where you have evidence, as
`<slot>=<Tool name>:cli`. Their notetaker is the `transcripts` slot.

```bash
bash core/packages/hq-pack-agency-kit/scripts/firm-setup.sh \
  --firm {firm} --agency-name "{agency_name}" --bind crm=Pipedrive:cli
```

Slots without evidence stay undecided. If it reports `E_ENV_YQ_MISSING`, note
it for the summary; client homes cannot be created until it runs.

## A brain for each client

Work out their current clients from what you read (Slack channels, recent
proposals and contracts in Drive, deals in a connected CRM) and let them
confirm or edit the list.

From Slack, the channel list is enough. Use all of it: `channels` returns
every channel (check `complete` is true), often hundreds. A channel shared
with another organization (`shared: true`) is almost always a client. Look
for the naming pattern the agency uses for client channels: a prefix or
suffix many shared channels have in common (`hqx-acme`, `client-acme`,
`acme-ext`) usually marks one channel per client, and the rest of the name is
the client. Names without a pattern can still be a company name.
Internal channels (general, random, team, eng, design, ops, alerts, sales,
hiring and the like) are not clients. Group channels that
belong to the same client (`acme`, `acme-ads`, `acme-seo`), and show the
person each proposed client with its channels so they can confirm, rename or
drop it. If nothing in the list looks like a client, say so and ask them to
name their clients. If they want to start with a few, set up only those. Write the confirmed list to a file in your memory folder, one per
line as `{slug}<TAB>{Client Name}`, and create every home in one go:

```bash
bash core/packages/hq-pack-agency-kit/scripts/import-clients.sh \
  --firm {firm} --file <that file> --agency-name "{agency_name}"
```

Then fill each client's `client-profile.md` and `access-and-assets.md` from
what you already read, every fact with its source, blank where you have
nothing. With a notetaker connected, add the client's recent meetings to its
profile (date, who, what was agreed, what is next); with a project tool, add
its open projects and their status. Put each client's Slack channels in its `access-and-assets.md`
(channel name, whether it is shared with the client, and its purpose). Systems are names only; never copy a credential.

## Finishing

Tell them what you set up: the playbook and SOPs, the client homes, what you
connected and linked, and anything not done, each with where to find it in
Files. Lead with the client workspaces: name each client and what you filled
in for it. Then offer the next step as a real choice: open one client's
workspace and walk through what is in it, or run a workflow on one client
(onboarding with `skills/onboarding.md`, a scope check or a weekly update with
`skills/clients.md`). Name the buttons so they never read as unfinished setup:
"Walk me through {Client}" and "Kick off {Client}" (the onboarding), not
"Onboard {Client}". Record `Setup: finished` and the date in your progress
note.

Only if they have no clients at all, offer a practice run on Northwind Labs,
a made-up client with problems hidden in its documents, loaded with
`scripts/practice-setup.sh --firm {firm} --agency-name "{agency_name}"`.

When something fails, say plainly what did not work and offer to try again
or move on; list anything skipped in the summary.
