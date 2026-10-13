---
name: agency-setup
description: First-run wizard for the HQ Agency Kit. Asks about the agency (name, services, ideal client, pricing, tools, voice), writes the agency playbook into companies/{firm}/knowledge/agency-playbook/, runs the client-service firm onboarding, and offers the practice client. Idempotent; never overwrites playbook files the agency has edited.
triggers:
  - agency setup
  - set up my agency
  - start the agency kit
  - configure my agency in hq
maturity: HQ-native (authored for this package)
---

# /agency-setup

Sets up an agency in HQ in about ten minutes. This is the HQ Agency Kit; the
user's agency is the one being set up, and its own name and voice
are what clients will see. At the end the agency has:

- an **agency playbook** every other skill works from;
- the **client-service** setup (client folders and the engagement template);
- optionally, the **practice client** loaded and ready for `/client-onboarding`.

Ask one question per `AskUserQuestion` call. Keep the tone friendly and short.
The person may be new to HQ, so explain each step in one plain sentence before
running it.

## Step 1: Which company is the agency?

The agency must be an existing HQ company. Resolve it in this order:

1. The session's bound company, if it is not `personal`. Confirm it with the user.
2. Otherwise list companies from `companies/manifest.yaml` and ask.
3. If the agency has no company yet, tell the user to create one with
   `/newcompany`, then come back. Do not create it from this skill.

Bind the session to it if it is not already bound:

```bash
bash core/scripts/hq-session.sh set company_slug {firm}
```

## Step 2: Ask about the agency

Ask these, one at a time. Offer 2 to 4 example answers as options and let the
user type their own. Skipping is fine: a skipped answer becomes a marked
placeholder they can fill in later.

1. **Agency name** as clients see it.
2. **What you sell**: services, and any packages or tiers.
3. **Who you sell to**: industry, size, and the buyer's job title.
4. **How you charge**: retainer, project, performance, or a mix.
5. **Tools you run**: CRM, project management, reporting, ad or delivery platforms.
6. **How you sound**: two or three words, or a sentence about your voice with clients.
7. **Where client work lives by default**: `folder` (each client is a folder
   inside this company; the usual choice) or `company` (each client also gets
   their own HQ company, for clients who will run HQ themselves or take the
   work with them). `/client-workspace` asks again per client.

## Step 3: Write the playbook

```bash
bash core/packages/hq-pack-agency-kit/scripts/agency-setup.sh \
  --firm {firm} --name "{name}" \
  --services "{services}" --ideal-client "{ideal client}" \
  --pricing "{pricing}" --tools "{tools}" --voice "{voice}" \
  --client-mode {folder|company}
```

It writes six files to `companies/{firm}/knowledge/agency-playbook/`:
`agency-profile.md`, `onboarding-checklist.md`, `audit-criteria.md`,
`scope-rules.md`, `examples.md` and `learnings.md`. Any file that already exists
is kept as it is.

Then read `onboarding-checklist.md`, `audit-criteria.md` and `scope-rules.md`
back and tailor them to the services from Step 2. For example, an agency that
builds automations gets audit criteria about current workflows and systems
instead of ad performance. Show the changes and get a yes before saving. Use the
Edit tool on the files; keep the structure.

## Step 4: Client-service setup

Run `/onboard-firm` for `{firm}`. It sets up the client folders and the engagement
template, and asks about the tools from Step 2. If the user wants to skip tool
connections for now, run it with every slot empty:

```bash
bash core/packages/hq-pack-client-service/scripts/onboard-firm.sh --company {firm} \
  --empty crm --empty billing --empty agreements --empty portal --empty transcripts
```

## Step 5: Offer the practice client

Ask: *"Want to try the onboarding system on a practice client first? It takes
about 15 minutes and uses made-up data."* If yes, run `/practice-client`.

## Step 6: Wrap up

Tell the user, in plain words:

- where their playbook lives, and that editing it changes how every skill works;
- the things to do next: `/practice-client`, then `/new-client`,
  `/client-workspace` and `/client-onboarding` when a real client signs;
- that `/scope-check`, `/weekly-update` and `/proposal` are available any time.

Re-running `/agency-setup` is safe. It only adds playbook files that are missing.
