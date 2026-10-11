# Changelog

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
