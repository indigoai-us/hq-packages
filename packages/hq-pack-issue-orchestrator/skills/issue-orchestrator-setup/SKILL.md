---
name: issue-orchestrator-setup
description: Configure and pilot an existing HQ agent as a guarded issue or ticket orchestrator. Use when the user wants to manage development issues, customer-support tickets, operational queues, feedback, or mixed issue sources through HQ; asks to select an agent, company, sources, goals, handoff, scope, permissions, lifecycle, or schedule; or wants a safe first pilot before enabling automation.
---

# Issue orchestrator setup

Create one tenant-scoped configuration and prove it with a read-only pilot. Ask one decision at a time with a structured picker when available. Persist completed answers after each phase so setup can resume.

## 1. Resolve the owner and agent

1. Resolve the company from `companies/manifest.yaml`. Offer `personal` only when the workflow is not company-owned.
2. List available agents from `core/workers/registry.yaml` and `companies/{company}/workers/`. Include only agents visible to the chosen company.
3. Ask the operator to select one existing agent. Do not provision a new identity from this skill; route that need to `/new-agent`.
4. Record the agent's stable ID and display name.

Write company configuration to `companies/{company}/settings/issue-orchestrator.json`; write personal configuration to `personal/settings/issue-orchestrator.json`.

## 2. Define the outcome

Ask for one to three measurable goals. Examples include reducing untriaged age, ensuring every customer report has an owner, producing investigation handoffs, or preparing draft fixes. Capture explicit non-goals. Never infer permission from a goal.

## 3. Select sources

Inventory only sources available to the chosen company. For each selected source, record the fields in `references/config-contract.md`:

- source type and non-secret locator;
- exact item eligibility rule;
- canonical conversation or issue location;
- immutable identity key and replay window;
- HQ secret key names, never values.

Prefer existing HQ connections and connector skills. If an external app is not connected, stop that source's setup at the connection boundary and name the required connector or `/new-connection` action. Do not replace a missing connection with copied credentials.

## 4. Set scope and lifecycle

Define include and exclude rules using the finest safe unit: repositories, projects, queues, channels, labels, customer tiers, or paths. Set `maxItemsPerRun` and `maxConcurrentWork` conservatively.

Confirm the lifecycle vocabulary. Default to `new`, `triaged`, `planned`, `in_progress`, `human_review`, `blocked`, and `resolved`. Require an explicit authorized human signal for every terminal transition. Merge, deployment, inactivity, or agent confidence never resolves an item.

## 5. Design the handoff

Choose the human destination and required fields. Every handoff must include source, summary, evidence, recommended next action, owner, and status. Add source-specific canonical links and thread coordinates where available.

Escalate on missing scope, conflicting instructions, unsafe actions, permission denial, uncertain resolution, exposed credentials, or insufficient evidence. Ask one precise question at the canonical item location when the source supports threads.

## 6. Grant permissions explicitly

Start with `read=true` and `classify=true`. Ask separately about comment, ticket creation, status change, assignment, and draft-change creation. Keep merge and deploy false. Keep close or resolve false unless a later activation explicitly binds it to an authorized human command.

The pilot requires every write permission false. Store credentials through `/hq-secrets` or the configured connection; the configuration contains secret key names only.

## 7. Write and validate configuration

Use `assets/config-template.json` as the shape and fill every placeholder. Read `references/config-contract.md` before writing. Then run:

```bash
python3 .claude/skills/issue-orchestrator-setup/scripts/validate_config.py <absolute-config-path>
```

Resolve every validation error before continuing. Never loosen the validator to accommodate an unsafe configuration.

## 8. Run the pilot

Read `references/pilot-contract.md`, then invoke `/issue-orchestrator pilot` with the config path. The pilot reads a bounded sample and writes a local report under `workspace/reports/issue-orchestrator/`; it performs no source, repository, messaging, ticket, or lifecycle writes.

Review the report with the operator. Check false inclusions and exclusions, dedupe evidence, proposed owners and actions, handoff completeness, and requested permissions. Record the activation decision and any config changes.

## 9. Activate or leave paused

If the operator approves, set `mode` to `active`, enable only the individually approved permissions, validate again, and schedule through the company's approved durable runner. Prefer an existing HQ worker schedule. Do not create cron, terminal loops, or an unowned background process.

If approval is withheld, leave `mode` as `pilot` or set it to `paused`. Report the exact blocker and the next safe test.

## Done criteria

Setup is complete only when:

- company or personal owner and existing agent are resolved;
- goals, sources, scope, lifecycle, handoff, permissions, and schedule are explicit;
- configuration passes the bundled validator;
- a bounded read-only pilot report exists and has been reviewed;
- activation or pause is recorded without implied permissions.
