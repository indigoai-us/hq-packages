---
name: practice-client
description: Load Northwind Labs, an invented practice client with deliberately planted problems, into the agency so students can run /client-onboarding end to end on day one without real client data. Creates the engagement record through client-service, loads the documents, then hands off to /client-onboarding and grades the run against the answer key.
triggers:
  - practice client
  - try the onboarding on a sample client
  - load the practice client
  - demo client
maturity: HQ-native (authored for this package)
---

# /practice-client

Northwind Labs is a made-up software company that just signed with the agency.
Its documents contain the kinds of problems real clients bring: scope that does
not match the sales call, campaigns that reward the wrong result, missing
access, and data with holes in it. The point is for the student to watch
`/client-onboarding` find them.

## Step 1: Check setup

The session must be bound to the agency company, and
`companies/{firm}/knowledge/agency-playbook/` must exist. If not, run
`/agency-setup` first. Read the agency name from `agency-profile.md`.

## Step 2: Create the engagement

Use client-service's engagement phase. Practice clients never get their own HQ
company.

```bash
bash core/packages/hq-pack-client-service/scripts/new-client.sh engagement \
  --firm {firm} --client practice-northwind \
  --client-name "Northwind Labs (practice)" --local-only
```

If it reports `E_SLUG_COLLISION`, the practice client already exists. Ask whether
to continue the existing practice run. Never delete it to start over without the
user's explicit yes.

## Step 3: Load the documents

```bash
bash core/packages/hq-pack-agency-kit/scripts/practice-client.sh \
  --firm {firm} --agency-name "{agency name}"
```

This copies the contract, proposal, sales call transcript, campaign export, CRM
export and landing page into `clients/practice-northwind/onboarding/inputs/`.
The answer key is left out.

## Step 4: Run onboarding

Tell the student what is about to happen in two sentences, then run
`/client-onboarding` for `practice-northwind`. Let the student act as the
strategist at each approval gate. Encourage them to push back on anything that
looks wrong; that is the skill they are practising.

## Step 5: Grade the run

When onboarding finishes, read the answer key in
`core/packages/hq-pack-agency-kit/examples/practice-client/inputs/README.md`
(section "For instructors"). For each of the eight planted issues, say whether
the run caught it, and where. For any it missed, show which playbook line would
have caught it and offer to add that line (this is Step 6 of `/client-onboarding`
in action).

## Cleaning up

The practice client lives at `companies/{firm}/clients/practice-northwind/`. It
is safe to keep. If the student wants it gone, confirm first, then remove that
one folder and its record in `workspace/client-service/new-client/`.
