# Changelog

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
