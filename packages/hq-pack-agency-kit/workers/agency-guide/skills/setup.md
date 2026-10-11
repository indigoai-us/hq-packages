---
name: setup
title: Agency setup
description: Set up the agency from the chat as a short interview. Six topics, one question at a time with suggested answers, a follow-up when an answer is vague, and the agency's own documents read instead of asked about. Then write the playbook, run the client-service firm setup with every slot empty, load Northwind Labs, and hand off to onboarding.
---

# Agency setup

This is the pack setup from `setup:` in the Agency Kit's package.yaml, done by
you in the chat. Treat it as an interview with a sharp strategist, not a form:
the playbook you write is only as good as what you learn here, and every
agency-kit skill reads it first. Keep each message short. One question per
message.

Before you start, resolve `{firm}` as the worker instructions say, and read
the company's display name from `companies/manifest.yaml`
(`companies.{firm}.name`). Record both in your progress note. If the app already
sent the first question (your turn starts with a `[Pack setup: ...]` note), do
not repeat the checks or the question: the person's message is their answer.

If `companies/{firm}/knowledge/agency-playbook/` already exists, setup has run
before. Say so in one line, offer ["Run Northwind's onboarding","Set up my agency again"],
and on the second run the steps below anyway: the scripts only add what is
missing and never overwrite a playbook file the agency has edited.

## How to interview

- **Each topic has a goal.** A topic is done when you know what its goal says,
  not when they have replied. A tap on a suggestion is often enough; a vague or
  surprising answer is not.
- **Follow up when it matters, once or twice at most.** "Variable pricing", "a
  mix", "depends on the client", "Something else" and similar always get one
  short follow-up, with suggestions where you can guess the likely answers. Do
  not follow up on a clear answer.
- **Use what they already told you.** If an earlier answer or a document
  covers a topic, propose what you know ("Sounds like retainer plus a share of
  ad spend. Right?") instead of asking from scratch.
- **Acknowledge in a few words** at the top of the next question ("Retainer
  plus 10% of spend over $50k, got it."). Never read back the whole set.
- **Record each topic in your progress note** as a full sentence the playbook
  can use, before you send the next question. This sentence is what you pass
  to the setup script, so write it the way the agency would describe itself.

## Documents first

Right after the agency name, ask once:

> Do you have any of these you can drop in here? A rate card or pricing sheet, a recent proposal or statement of work, or a case study. I'll read them and skip the questions they answer.

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["I'll add some","Not now"]}]}
```

When files arrive, read them. Tell them in two or three lines what you took
from them (services, prices and how pricing is built, typical clients, tone),
then carry on with the topics they did not cover, proposing what you found for
the ones they did. Note in your progress note which files you read. "Not now"
means carry on; do not ask again.

## The six topics

**1. agency_name** (not skippable). Goal: the name clients know them by.
Propose the company's display name and ask to confirm it; do not ask from
scratch.

> Your agency is called {Company display name} in HQ. Is that what clients see, or do they know you by another name?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Yes, {Company display name}","It's a different name"]}]}
```

A name is required; if they try to skip, say one line about why (it goes on
every brief and client update) and ask again.

**2. services**. Goal: what they sell and, for each service, what the client
actually gets, enough to tell in-scope work from out-of-scope work.

> What do you sell?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Paid ads","SEO and content","Web and design","Automations and AI","Something else","Skip"]}]}
```

Follow up if the answer is a channel with no detail ("Google Ads": "Search
only, or Shopping and Performance Max too? And do you make the creative?").

**3. ideal_client**. Goal: who they do their best work for, sharp enough to
spot a bad-fit lead: industry, size or spend, and stage.

> Who do you sell to?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Ecommerce brands","B2B SaaS","Local businesses","Professional services","Skip"]}]}
```

Follow up once for size if they only name an industry ("What size, roughly?
By revenue or monthly ad spend.").

**4. pricing**. Goal: how a price is built, well enough to check a proposal
or a scope change against it: the model (retainer, project, performance), what
it varies with, and typical ranges or minimums.

> How do you charge?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Monthly retainer","Per project","Performance based","A mix","Skip"]}]}
```

"Variable", "a mix" or "it depends" always gets a follow-up on what it
depends on:

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Ad spend","Scope of work","Results","Number of channels"]}]}
```

Then, if they have not said, ask for a typical range or minimum in one line
("What's a typical monthly fee, or your minimum?"). If a rate card or proposal
came in, take the numbers from it and ask them to confirm.

**5. tools**. Goal: the CRM, project management, reporting and ad platforms
they use, so later steps know where data lives. Do not ask about connecting
them; that comes later.

> Which tools do you run? CRM, project management, reporting, ad platforms.

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["HubSpot and Asana","Notion and Slack","Google Sheets and email","Not sure yet","Skip"]}]}
```

**6. voice**. Goal: how they sound with clients, specific enough to write in.
A proposal or case study they shared is the best source; propose what you
heard in it.

> How do you sound with clients, in a few words?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Direct and plain","Warm and friendly","Formal and precise","Skip"]}]}
```

"Skip" on any topic but the name records it as empty, and the playbook gets a
marked placeholder they can fill in later.

## Then do the work

After the last topic, say one line ("Writing your playbook now.") and run
these from the HQ root, in order. Pass each topic's sentence from your note;
leave out the flag of a skipped topic, and the script writes the placeholder.

1. The playbook:

   ```bash
   bash core/packages/hq-pack-agency-kit/scripts/agency-setup.sh \
     --firm {firm} --name "{agency_name}" \
     --services "{services}" --ideal-client "{ideal_client}" \
     --pricing "{pricing}" --tools "{tools}" --voice "{voice}"
   ```

   Check that `companies/{firm}/knowledge/agency-playbook/` has six files.
   If documents came in, add a short "From their documents" section to
   `agency-profile.md` with the specifics the six sentences could not hold
   (price points, packages, minimums, contract terms), each with the file it
   came from.

2. The firm setup and the practice client (the client-service firm setup with
   every slot empty, Northwind Labs recorded, and its documents loaded):

   ```bash
   bash core/packages/hq-pack-agency-kit/scripts/practice-setup.sh \
     --firm {firm} --agency-name "{agency_name}"
   ```

   Check that `companies/{firm}/clients/practice-northwind/onboarding/inputs/`
   has seven files.

Record each step in your progress note as it finishes. Do not narrate the
steps to the person; they get one message at the end.

If a script fails, say in one plain sentence what you were doing and that it
did not finish (for example "I couldn't write the playbook yet."), and offer
["Retry","Skip this for now"]. Never show the error text. On Retry, run the
same step again. On Skip, record it in your note and continue; say at the end
what was skipped and that you can pick it up any time.

## The done message

When both steps have run, send exactly this, with the suggestion from
`setup.done`:

> Your agency playbook is written. You'll find it in Files under Knowledge, Agency Playbook. Northwind Labs just signed with you.

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Run Northwind's onboarding"]}]}
```

Write `Setup: finished` and the date in your progress note. When they tap the
suggestion (or say anything that means yes), run `skills/onboarding.md` for
`practice-northwind`.
