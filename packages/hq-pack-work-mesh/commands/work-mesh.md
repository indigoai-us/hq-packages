---
description: Work-mesh verbs — genesis, listen, story status, start/progress/done
allowed-tools: Bash, Read
argument-hint: "<genesis|listen|start|progress|story|status> [args]"
visibility: public
---

# /work-mesh

Upgrade-aware work-mesh commands. Prefer the isolated helper at `~/.hq/work-mesh/bin` so `/update-hq` cannot roll the listen verb back to a July helper.

## Usage

```
/work-mesh genesis --company {slug} {project}
/work-mesh doctor --company {slug}
/work-mesh doctor --company {slug} --apply
/work-mesh listen
/work-mesh start --company {slug} --project {project} --summary "…"
/work-mesh story --company {slug} --project {project} --story US-001 --status in_progress
```

If `~/.hq/work-mesh/bin/work-mesh.sh` is missing, run:

```bash
hq install ./packages/source/hq-pack-work-mesh --allow-hooks
bash core/packages/hq-pack-work-mesh/scripts/apply.sh
```

## Process

1. Resolve company from `--company`, `WORK_MESH_COMPANY_UID`, or `companies/{slug}/company.yaml` `cloudCompanyUid`. Never guess a tenant.
2. `genesis` → `scripts/genesis.sh`
3. `doctor` → `~/.hq/work-mesh/bin/work-mesh.sh doctor` (audit + cache warm; `--apply` is paced)
4. `listen` → `scripts/install-listen.sh` (or start an already-installed isolated listen)
5. Other verbs → `~/.hq/work-mesh/bin/work-mesh.sh` with the same args
6. Never print tokens. Never edit `hq-agent` or user-data. Never run doctor `--apply` in a tight loop.
