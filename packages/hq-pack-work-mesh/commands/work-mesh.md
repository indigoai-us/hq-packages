---
description: Work-mesh verbs — genesis, doctor, and pointers to hq mesh daemon/session/context
allowed-tools: Bash, Read
argument-hint: "<genesis|doctor|daemon|session|context> [args]"
visibility: public
---

# /work-mesh

Pack helpers for genesis and doctor. Presence and spool flush are **hq-cli**:

```
hq mesh daemon install
hq mesh session task-status|blocked|note …
hq mesh context reconcile|organize|default|untracked …
```

## Usage

```
/work-mesh genesis --company {slug} {project}
/work-mesh doctor --company {slug}
/work-mesh doctor --company {slug} --apply
```

`listen` was removed in pack 0.2.0. If a machine still has
`ai.getindigo.hq-work-mesh-listen`, run:

```bash
bash core/packages/hq-pack-work-mesh/scripts/apply.sh
hq mesh daemon install
```

## Process

1. Resolve company from `--company`, `WORK_MESH_COMPANY_UID`, or
   `companies/{slug}/company.yaml` `cloudCompanyUid`. Never guess a tenant.
2. `genesis` → `scripts/genesis.sh`
3. `doctor` → pack helper doctor (audit + cache warm; `--apply` is paced) when
   the isolated helper exists; otherwise prefer `hq mesh daemon doctor`
4. Never print tokens. Never edit `hq-agent` or user-data.
