# AI Builders Agency Kit

An HQ pack for service agencies, built for the AI Builders cohort. It turns a
signed client into a sourced client brief, an intake request, an account audit
and a kickoff package a strategist can review before kickoff. It also writes
every lesson the strategist catches back into the agency's playbook.

Built on `hq-pack-client-service`, which provides client folders, engagement
records and client handover.

## Requirements

- hq-core 16.0.0-beta.50 or newer (multi-company sessions)
- hq-cli 5.345.62 or newer
- `hq-pack-client-service` installed

## Install

```bash
hq packages install /path/to/hq-pack-agency-kit
```

Then run `/agency-setup`.

## What's inside

| Skill | What it does |
|---|---|
| `/agency-setup` | Asks about the agency and writes its playbook: profile, onboarding checklist, audit criteria, scope rules, examples, learnings, default client workspace mode. Runs `/onboard-firm`. |
| `/client-workspace` | Gives a client the standard workspace layout. Folder mode keeps the client inside the agency company; company mode also gives the client its own HQ company. |
| `/client-onboarding` | The onboarding system: scope review, missing inputs, account audit, kickoff package, engagement update, playbook learnings. Four approval gates. |
| `/practice-client` | Loads Northwind Labs, an invented client with eight planted problems, and grades the onboarding run against an answer key. |
| `/scope-check` | Checks a client request against the contract and scope rules, and drafts the reply. |
| `/weekly-update` | Drafts the client's weekly update from the engagement record. |
| `/proposal` | Drafts a proposal with an explicit scope and exclusions, so the contract and onboarding are clean. |

Policies:

- `agency-kit-evidence-before-commitment` (hard): every finding cites its
  source, gaps in the data are stated, nothing reaches a client without approval.
- `agency-kit-playbook-learns`: strategist corrections go back into the playbook.

Brand: `brand/BRAND.md` and `brand/tokens.css` hold the AI Builders palette,
type and voice for anything the pack renders for a student. The agency's own
brand lives in its playbook and is what clients see.

## Where things go

| What | Path |
|---|---|
| Playbook | `companies/{firm}/knowledge/agency-playbook/` |
| Client workspace | `companies/{firm}/clients/{slug}/` (`client-profile.md`, `access-and-assets.md`, `onboarding/`, `reports/`) |
| Client documents | `companies/{firm}/clients/{slug}/onboarding/inputs/` |
| Onboarding outputs | `companies/{firm}/clients/{slug}/onboarding/` |
| Client's own HQ (company mode) | `companies/{client}/` |
| Proposals | `companies/{firm}/knowledge/proposals/{slug}/` |

## A client, start to finish

1. `/proposal` before they sign.
2. `/new-client` when they sign: the engagement record.
3. `/client-workspace`: the standard folders, and the folder-or-company choice.
4. Drop the contract and documents into `onboarding/inputs/`.
5. `/client-onboarding`: brief, intake, audit, kickoff package.
6. `/scope-check` and `/weekly-update` through the engagement.
7. `/handover-client` if the client has their own HQ at the end.

See `knowledge/agency-kit/README.md` for how the pieces fit, including working
across the agency's and a client's HQ companies in one session.

## Tests

```bash
bash tests/run.sh
```

Covers the setup, workspace and practice scripts against a throwaway HQ root,
package consistency, and that the practice data matches its answer key.
