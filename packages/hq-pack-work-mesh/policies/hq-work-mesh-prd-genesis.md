---
id: hq-work-mesh-prd-genesis
title: Cloud-backed /prd must run work-mesh genesis after board upsert
when: prd || genesis || new project || board upsert
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 1
created: 2026-08-16
public: true
---

## Rule

After `/prd` writes `prd.json` and upserts the company board, run work-mesh genesis for that cloud-backed company so a mesh thread, invite-only project channel, sidecar, and `PROJECT_VIEW` exist before anyone opens a desktop.

```bash
bash core/scripts/hq-work-mesh-genesis.sh --company {slug} {project}
```

Fail the step if genesis exits non-zero. Do not call another company's genesis script. Skip only for personal/HQ (no company mesh) or when the company has no `cloudCompanyUid`.
