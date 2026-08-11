# HQ Issue Orchestrator

Turn an existing HQ agent into a guarded issue manager for development, customer support, operations, or another ticketed workflow.

The pack is source-agnostic. A setup walkthrough helps the operator select the company and agent, connect one or more issue sources, define goals and lifecycle states, set scope and permissions, choose handoff and escalation rules, and prove the configuration with a read-only pilot before enabling writes.

## Install

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-issue-orchestrator
```

Then run `/issue-orchestrator-setup`.

## What it installs

- `/issue-orchestrator-setup`: guided setup and pilot workflow
- `/issue-orchestrator`: repeatable operating loop for configured sources
- `issue-orchestrator` knowledge: lifecycle, safety, adapter, and pilot contracts

Configuration is company-scoped by default at `companies/{company}/settings/issue-orchestrator.json`. Personal use writes to `personal/settings/issue-orchestrator.json`. The configuration stores secret key names only, never credentials.

The default mode is `pilot`. A pilot may read and classify a bounded sample, but it cannot comment, create tickets, change status, assign work, merge, deploy, close, or resolve anything.
