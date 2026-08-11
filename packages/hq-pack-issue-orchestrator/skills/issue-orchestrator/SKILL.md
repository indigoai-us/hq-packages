---
name: issue-orchestrator
description: Run a configured HQ issue or ticket orchestration loop across development, customer-support, feedback, or operational sources. Use when the user asks to triage a configured queue, run the issue manager, inspect its status, execute a read-only pilot, prepare handoffs, or advance eligible items under the permissions created by issue-orchestrator-setup.
---

# Issue orchestrator

Require an absolute config path or resolve the active company's `companies/{company}/settings/issue-orchestrator.json`, falling back to `personal/settings/issue-orchestrator.json` only for personal scope. Validate it with the setup skill's `scripts/validate_config.py` before reading any source.

## Modes

- `status`: report configured agent, sources, mode, scope caps, permissions, last run, and blockers without source writes.
- `pilot`: follow the setup skill's pilot contract and write a report under `workspace/reports/issue-orchestrator/`. Never write to a source.
- `run`: require `mode=active`; process no more than `scope.maxItemsPerRun` with no more than `scope.maxConcurrentWork` active items.

## Operating loop

1. Resolve the company and enforce tenant isolation before every source read.
2. Collect eligible source-native items with bounded pagination and a fixed run window.
3. Deduplicate exact identities. Treat similarity grouping as a reversible proposal with retained evidence.
4. Classify scope, urgency, owner, lifecycle state, and next action against the configured goals.
5. Act only when the exact permission boolean is true. No goal, prior action, or broad source credential implies permission.
6. Produce the configured handoff. Keep communication at the canonical item location.
7. Checkpoint successful phases, record per-item failures, release stale leases, and report health.

## Hard boundaries

- Never cross company scope or use another company's source, credential, or repository.
- Never print or persist credential values.
- Never merge or deploy. These permissions remain false and belong to existing review and release workflows.
- Never close or resolve from merge, deployment, inactivity, confidence, or a bot message. Require the configured authorized human signal.
- Never hide suppressed, blocked, human-review, or failed items from the audit trail.
- Never claim a successful batch from an HTTP success alone; inspect per-item failures.
- Stop and hand off on exposed credentials, unsafe action requests, unclear scope, conflicting human direction, or missing evidence.
