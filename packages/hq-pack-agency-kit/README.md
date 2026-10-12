# AI Builders Agency Kit

An HQ pack for service agencies, built for the AI Builders cohort. It turns a
signed client into a sourced client brief, an intake request, an account audit
and a kickoff package a strategist can review before kickoff. It also writes
every lesson the strategist catches back into the agency's playbook.

Built on `hq-pack-client-service`, which provides client folders, engagement
records and client handover.

There are two doors in. The first is the HQ app: add the pack and a bot
called the **Agency Guide** appears in Messages, asks six questions, writes
the playbook, loads a practice client and runs its onboarding with you, all
in the chat. The second is Claude Code, where the same flows are slash
commands. Both write the same files.

## Requirements

- hq-core 16.0.0-beta.50 or newer (multi-company sessions)
- hq-cli 5.345.62 or newer
- `hq-pack-client-service` installed

## From the HQ app: meet the Agency Guide

1. **Add the pack.** Open the pack page at hqforwork.com/packs/agency-kit and
   choose Add to HQ, or paste that link to your Setup bot in Messages. HQ
   installs the pack and starts a personal bot named `agency-guide`
   ("Agency Guide"). If HQ's own setup is not finished, the Agency Guide
   finishes it first.
2. **Six questions.** The Guide proposes your company's name as the agency
   name and asks you to confirm it, then asks what you sell, who you sell to,
   how you charge, which tools you run, and how you sound with clients. Each
   question comes with tap-to-answer suggestions and Skip; typing works too.
   A skipped answer becomes a marked placeholder in the playbook.
3. **The playbook is written.** You will find it in Files, under Knowledge,
   Agency Playbook. The Guide also runs the client-service firm setup with
   every tool connection left empty (connect tools later, when you want
   them).
4. **Northwind Labs signs with you.** A made-up client with eight planted
   problems lands in Files, under Clients, Northwind Labs (practice). Tap
   "Run the practice onboarding" and the Guide produces the client brief, the
   intake request, the account audit and the kickoff package one at a time.
   Each step ends with a two-line summary, where the file is in Files, and
   Approve / Needs changes. Approve records your name and the date in the
   file; Needs changes takes one message of corrections and stops at that
   step. At the end the Guide grades the run against the answer key.
5. **Real clients.** Say "new client Atlas" and the Guide creates the
   engagement record, asks whether Atlas is a folder in your agency or gets
   their own HQ company, and tells you where to drop the documents (Files,
   under Clients, Atlas, onboarding, inputs). Then "onboard Atlas", "is this
   in scope: ...", and "weekly update for Atlas". Every draft is saved under
   the client's reports folder and shown to you for approval. The Guide never
   sends anything to anyone.

The Guide never asks you to open a terminal or Claude Code, and names every
file as a location in the Files tab.

The bot and its setup are declared in `package.yaml` (`setup:` and
`workers/agency-guide/`). The bot's worker has three skills: `setup`,
`onboarding` and `clients`. Its generic HQ-setup skills come from hq-cli
when a takeover is needed; the pack does not copy them.

## From Claude Code (optional)

```bash
hq packages install /path/to/hq-pack-agency-kit
```

Then run `/agency-setup`. Everything the Agency Guide does is also a slash
command, listed below, for people who prefer to work in Claude Code.

## What's inside

Worker:

| Worker | What it does |
|---|---|
| `agency-guide` | The Agency Guide bot: pack setup in chat (six questions, tap to answer), Northwind onboarding with approval gates, and the real-client flows (`new client`, `onboard`, `is this in scope`, `weekly update for`). Drafts only, never sends. |

Claude Code skills (optional; the Guide runs the same methods):

| Skill | What it does |
|---|---|
| `/agency-setup` | Asks about the agency and writes its playbook: profile, onboarding checklist, audit criteria, scope rules, examples, learnings, default client workspace mode. Runs `/onboard-firm`. |
| `/client-workspace` | Gives a client the standard workspace layout. Folder mode keeps the client inside the agency company; company mode also gives the client its own HQ company. |
| `/client-onboarding` | The onboarding system: scope review, missing inputs, account audit, kickoff package, engagement update, playbook learnings. Four approval gates. |
| `/practice-client` | Loads Northwind Labs, an invented client with eight planted problems, and grades the onboarding run against an answer key (`scripts/grade-practice.sh`). |
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

| What | In the Files tab | Path |
|---|---|---|
| Playbook | Knowledge > Agency Playbook | `companies/{firm}/knowledge/agency-playbook/` |
| Client workspace | Clients > {Client} | `companies/{firm}/clients/{slug}/` (`client-profile.md`, `access-and-assets.md`, `onboarding/`, `reports/`) |
| Client documents | Clients > {Client} > onboarding > inputs | `companies/{firm}/clients/{slug}/onboarding/inputs/` |
| Onboarding outputs | Clients > {Client} > onboarding | `companies/{firm}/clients/{slug}/onboarding/` |
| Approved drafts (scope checks, weekly updates) | Clients > {Client} > reports | `companies/{firm}/clients/{slug}/reports/` |
| Client's own HQ (company mode) | the client's company | `companies/{client}/` |
| Proposals | Knowledge > proposals | `companies/{firm}/knowledge/proposals/{slug}/` |

## A client, start to finish

In the chat, with the Agency Guide: "new client {name}", drop the documents
into Files, "onboard {name}", then "is this in scope: ..." and "weekly update
for {name}" through the engagement.

In Claude Code:

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
the `setup:` block (bot name, question ids, scripts and flags), the
`agency-guide` worker files, the practice grader against a fixture (and that it
fails when an issue is removed), package consistency, and that the practice
data matches its answer key.
