---
name: setup
title: Agency setup
description: Set up the agency from the chat. Six questions, one at a time, each with suggested answers and Skip. Then write the playbook, run the client-service firm setup with every slot empty, load Northwind Labs, and hand off to onboarding.
---

# Agency setup

This is the pack setup from `setup:` in the Agency Kit's package.yaml, done by
you in the chat. It takes about ten minutes and the person types nothing but
their answers. Keep every message short. One question per message.

Before you start, resolve `{firm}` as the worker instructions say, and read
the company's display name from `companies/manifest.yaml`
(`companies.{firm}.name`). Record both in your progress note.

If `companies/{firm}/knowledge/agency-playbook/` already exists, setup has run
before. Say so in one line, offer ["Run Northwind's onboarding","Set up my agency again"],
and on the second run the steps below anyway: the scripts only add what is
missing and never overwrite a playbook file the agency has edited.

## The six questions

Ask them in this order, one per message, and record each answer in your
progress note before sending the next question. A tap and a typed reply are
the same thing: whatever the person's message says is the answer. "Skip"
records the answer as empty, and the playbook gets a marked placeholder they
can fill in later.

**1. agency_name** (not skippable). Propose the company's display name and ask
to confirm it; do not ask from scratch.

> Your agency is called {Company display name} in HQ. Is that what clients see, or do they know you by another name?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Yes, {Company display name}","It's a different name"]}]}
```

If they tap the first item, the answer is the display name. If they tap the
second or type a name, ask for or take the name they give. A name is required;
if they try to skip, say one line about why you need it (it goes on every
brief and client update) and ask again.

**2. services**

> What do you sell?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Paid ads","SEO and content","Web and design","Automations and AI","Something else","Skip"]}]}
```

"Something else" means: ask them to describe it in a line, then take that.

**3. ideal_client**

> Who do you sell to?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Ecommerce brands","B2B SaaS","Local businesses","Professional services","Skip"]}]}
```

**4. pricing**

> How do you charge?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Monthly retainer","Per project","Performance based","A mix","Skip"]}]}
```

**5. tools**

> Which tools do you run? CRM, project management, reporting, ad platforms.

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["HubSpot and Asana","Notion and Slack","Google Sheets and email","Not sure yet","Skip"]}]}
```

**6. voice**

> How do you sound with clients, in a few words?

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Direct and plain","Warm and friendly","Formal and precise","Skip"]}]}
```

Acknowledge each answer in a few words at the top of the next question
("Paid ads, got it."). Never summarize all the answers back, and never ask
them to confirm the whole set.

## Then do the work

After the sixth answer, say one line ("Writing your playbook now.") and run
these from the HQ root, in order. Pass only the answers that were given; a
skipped question's flag is left out, and the script writes the placeholder.

1. The playbook:

   ```bash
   bash core/packages/hq-pack-agency-kit/scripts/agency-setup.sh \
     --firm {firm} --name "{agency_name}" \
     --services "{services}" --ideal-client "{ideal_client}" \
     --pricing "{pricing}" --tools "{tools}" --voice "{voice}"
   ```

   Check that `companies/{firm}/knowledge/agency-playbook/` has six files.

2. The client-service firm setup, with every slot empty (the person can
   connect tools later; never ask about tool connections during setup):

   ```bash
   bash core/packages/hq-pack-client-service/scripts/onboard-firm.sh --company {firm} \
     --empty crm --empty billing --empty agreements --empty portal --empty transcripts
   ```

   Check that `companies/{firm}/clients/` exists.

3. The practice client's engagement record, then its documents:

   ```bash
   bash core/packages/hq-pack-client-service/scripts/new-client.sh engagement \
     --firm {firm} --client practice-northwind \
     --client-name "Northwind Labs (practice)" --local-only
   bash core/packages/hq-pack-agency-kit/scripts/practice-client.sh \
     --firm {firm} --agency-name "{agency_name}"
   ```

   `E_SLUG_COLLISION` from the first means Northwind already exists; carry on.
   `E_INPUTS_EXIST` from the second means its documents are already loaded;
   carry on. Check that
   `companies/{firm}/clients/practice-northwind/onboarding/inputs/` has seven
   files.

Record each step in your progress note as it finishes. Do not narrate the
steps to the person; they get one message at the end.

If a script fails, say in one plain sentence what you were doing and that it
did not finish (for example "I couldn't write the playbook yet."), and offer
["Retry","Skip this for now"]. Never show the error text. On Retry, run the
same step again. On Skip, record it in your note and continue; say at the end
what was skipped and that you can pick it up any time.

## The done message

When all three steps have run, send exactly this, with the suggestion from
`setup.done`:

> Your agency playbook is written. You'll find it in Files under Knowledge, Agency Playbook. Northwind Labs just signed with you.

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Run Northwind's onboarding"]}]}
```

Write `Setup: finished` and the date in your progress note. When they tap the
suggestion (or say anything that means yes), run `skills/onboarding.md` for
`practice-northwind`.
