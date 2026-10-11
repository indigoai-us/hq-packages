---
name: client-workspace
description: Set up a client's workspace from the Agency Kit template after /new-client. Scaffolds client-profile.md, access-and-assets.md, onboarding/inputs/ and reports/ under companies/{firm}/clients/{slug}/, and, in company mode, walks through giving the client its own HQ company for client-facing work and handover. Idempotent; never overwrites files the agency has edited.
triggers:
  - client workspace
  - set up the client folder
  - scaffold the client workspace
  - give this client their own company
  - should this client be a folder or a company
maturity: HQ-native (authored for this package)
---

# /client-workspace

Every client gets the same folder layout, so every skill knows where to look.
This skill adds that layout to a client's engagement folder, and decides where
the client's own work lives:

| Mode | Where client work lives | When to use it |
|---|---|---|
| **folder** | `companies/{firm}/clients/{slug}/` only | Most clients. Fast, nothing to hand over. |
| **company** | the folder above, plus the client's own HQ company at `companies/{slug}/` | Clients who will run HQ themselves, need their own team in it, or will take the work with them at the end. |

Internal notes stay in the firm folder in both modes (policy
`client-service-internal-external-split`). Firm skills reach a client company
only through `/client-pack`, never by copying (policy
`client-service-materialize-not-mount`).

## Step 1: Check the setup

1. Resolve `{firm}` from the session's bound company. If the session is not
   bound, ask which company is the agency. Do not guess.
2. Confirm `companies/{firm}/knowledge/agency-playbook/agency-profile.md`
   exists. If not, point the user at `/agency-setup`.
3. Resolve `{slug}`. If the user did not name a client, list
   `companies/{firm}/clients/`, skipping `_`-prefixed folders, and ask.
4. If `companies/{firm}/clients/{slug}/` does not exist, run `/new-client`
   first. This skill never creates the engagement record.

## Step 2: Pick the mode

Read the playbook default from `agency-profile.md` (the line
`Default client workspace:`). Ask one question with `AskUserQuestion`:

*"Should {Client} be a folder inside your agency, or get their own HQ company?"*
Offer the playbook default first, and say in one sentence what each means
(table above). The answer only applies to this client; the playbook default
stays as it is unless the user asks to change it.

## Step 3: Scaffold the workspace

```bash
bash core/packages/hq-pack-agency-kit/scripts/client-workspace.sh \
  --firm {firm} --client {slug} --client-name "{Client Name}" --mode {folder|company}
```

It writes, under `companies/{firm}/clients/{slug}/`:

- `README.md`: what each file and folder is for, and the mode.
- `client-profile.md`: who the client is and why they hired the agency.
- `access-and-assets.md`: the access, assets and approval contacts tracker.
- `onboarding/inputs/README.md` and `reports/README.md`.

Files that already exist are kept. Run with `--dry-run` first if unsure.

## Step 4: Company mode only

The script prints the steps. Run them in order, confirming with the user before
each one that creates or changes something:

1. `/newcompany {slug}` if `companies/{slug}/` does not exist yet.
2. `bash core/scripts/hq-session.sh add company {slug}` to work in both
   companies from this session. The firm stays the primary company. If this
   reports that multi-company sessions are off, stop and tell the user an HQ
   administrator has to enable `hooks.multi-company-session-lock`; the folder
   half of the workspace is complete and usable in the meantime.
3. `new-client.sh client-home` as printed, to write the client's
   `handover-checklist.md` in the client company.
4. `bash core/scripts/hq-session.sh remove company {slug}` when finished.

Client-team invites are outward-facing and stay behind `/new-client`'s approval
gate. Do not send any from here.

## Step 5: Wrap up

Tell the user, in plain words:

- the folder path, and that `client-profile.md` and `access-and-assets.md`
  are theirs to fill in or let `/client-onboarding` fill;
- to drop the contract and any documents into `onboarding/inputs/`, then run
  `/client-onboarding`;
- in company mode, which company the client's own work goes in, and that
  nothing internal is ever copied there.

Re-running `/client-workspace` is safe. It only adds files that are missing.
