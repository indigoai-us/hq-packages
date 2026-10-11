# Changelog

## 0.4.2 (2026-10-11)

- The tool interview is one question ("Which tools do you use for email, your
  CRM, team chat, docs and SOPs, and projects? For example: ..."), answered in
  one line.
- Sign-in links come from `hq integrations connect --link-only`, which returns
  the link at once; plain `--no-browser` waited for a sign-in the person had
  not been sent and stalled the chat.
- The guide does not narrate its steps; everything it writes is posted.

## 0.4.1 (2026-10-11)

- Setup starts with a short interview about the agency's tools, one tap per
  kind (email, CRM, team chat, docs, project management), then sends a
  sign-in link for each tool picked, one at a time. `setup.sources` lists the
  kinds with their likely tools and the domains HQ connects. Tools are named
  by kind until the person says which one they use. The `tools` topic comes
  from the interview and is no longer asked.

## 0.4.0 (2026-10-11)

- Setup builds three things: an agency brain (playbook plus the agency's own
  SOPs under `knowledge/agency-playbook/sops/`), a brain for each current
  client, and the agency's systems connected. The Agency Guide learns from
  connected apps and documents first (Gmail, Slack, HubSpot, Google Drive),
  proposes answers with their sources, and asks only what is left open.
- Current clients come in during setup: the guide proposes them from CRM
  deals, client Slack channels and email, the person confirms, and
  `scripts/import-clients.sh` creates every client home in one step. The
  guide then fills each `client-profile.md` and `access-and-assets.md` from
  what it read, with sources.
- `scripts/firm-setup.sh` links the client-service slots to the tools the
  agency uses (`--bind crm=HubSpot:cli`) and leaves the rest undecided
  instead of forcing them empty.
- Setup ends with a summary of what was set up and next steps ("Onboard a
  client"). Northwind Labs is offered only when the agency has no clients in
  HQ yet; `setup.run.then` no longer loads it.
- `scripts/practice-setup.sh` and the new scripts pass `--session-company`, so
  they work outside an HQ session.

## 0.3.3 (2026-10-11)

- The Agency Guide learns from connected apps before asking. After the agency
  name it lists the company's usable HQ integrations, offers to read recent
  sent client emails, client Slack channels and HubSpot deals (or to connect
  them), reads with read-only tools after a yes, and proposes answers with
  their sources for the person to confirm. `setup.sources` lists Gmail, Slack
  and HubSpot. It asks only the topics the data left open.
- The done message says Northwind Labs is a made-up practice client and asks
  whether to run its onboarding; the button reads "Run the practice
  onboarding".

## 0.3.2 (2026-10-11)

- Setup is an interview. Each `setup:` question has a `goal`, and the block
  lists `documents` (rate card, recent proposal, case study). The Agency Guide
  follows up once on a vague answer ("variable pricing": what does it vary
  with?), asks early for those documents, reads them, and adds what it found
  to the agency profile. Answers reach the playbook as full sentences.
- `scripts/practice-setup.sh` runs the steps after the playbook in one
  command: the client-service firm setup with every slot empty, Northwind Labs
  recorded, and its documents loaded. Safe to re-run. `setup.run.then` calls
  it, so every step the setup needs is declared in package.yaml.

## 0.3.1 (2026-10-11)

- Declare the client-service dependency as `requires.packs` (name and
  version range), the field hq-cli reads. A marketplace install of the kit
  now installs hq-pack-client-service 0.2.0 or later first; before, the old
  `requires.packages` list was ignored and a slug install skipped it.

## 0.3.0 (2026-10-11)

- The chat door. `package.yaml` gets a `setup:` block (bot `agency-guide`,
  display name "Agency Guide", six questions with suggested answers,
  `run` mapped to `scripts/agency-setup.sh`, then `scripts/practice-client.sh`,
  done message and the "Run Northwind's onboarding" suggestion,
  `takeover_setup: true`). `hq packages install --start-bot` starts the bot.
- New worker `workers/agency-guide/` (contributed under `core/workers/public/`):
  a personal bot that runs the pack setup in the HQ app chat, confirms the
  agency name from the company's display name, writes the playbook, runs the
  client-service firm setup with every slot empty, loads Northwind Labs, and
  runs onboarding step by step with Approve / Needs changes at each gate.
  Approve records the person's name and the date in the file and the status
  table. Skills: `setup`, `onboarding`, `clients` (new client, onboard, scope
  check, weekly update, drafts saved under the client's `reports/`, never
  sent). The worker never asks for a terminal or Claude Code and names every
  file as a Files-tab location.
- New script `scripts/grade-practice.sh`: grades a Northwind run against the
  instructor answer key and reports which of the eight planted issues were
  found; exits non-zero if any is missing. The Guide runs it after the kickoff
  package; `/practice-client` can use it too.
- Tests: the setup block (bot name in `contributes.workers`, unique question
  ids, `run.script`, `then` scripts and `args` flags exist), every worker file,
  the grader against a fixture (passes complete, fails with one issue removed).
- README and welcome describe the chat door; the Claude Code commands stay
  documented as optional.

## 0.2.0 (2026-10-11)

- New skill `/client-workspace` and script `scripts/client-workspace.sh`: one
  workspace layout for every client (`README.md`, `client-profile.md`,
  `access-and-assets.md`, `onboarding/inputs/`, `reports/`), scaffolded from
  `templates/client-workspace/`. Two modes: `folder` (inside the agency
  company) and `company` (the client also gets its own HQ company). Never
  overwrites.
- `/agency-setup` asks for the default client workspace mode and writes it to
  `agency-profile.md` (`--client-mode folder|company`, default folder).
- AI Builders brand: `brand/BRAND.md` and `brand/tokens.css`, with the rule that
  HQ and its commands are never renamed. Install welcome and README updated.
- Pack now lives in the hq-packages repo under `packages/hq-pack-agency-kit`.
- Tests cover the workspace script (placeholders, modes, keep-on-rerun, dry run,
  missing engagement) and the new playbook field.

Not yet built: members-only distribution tied to AI Builders VIP, a branded
install page, a `/agency-tutorial` for the course modules, a monthly report
skill, a client health check, and service add-on bundles.

## 0.1.0 (2026-10-09)

First version.

- Skills: `/agency-setup`, `/client-onboarding`, `/practice-client`,
  `/scope-check`, `/weekly-update`, `/proposal`.
- Agency playbook templates.
- Northwind Labs practice client with eight planted issues and an answer key.
- Policies: `agency-kit-evidence-before-commitment`, `agency-kit-playbook-learns`.
- Script tests (`tests/run.sh`).
