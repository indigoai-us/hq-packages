---
id: hq-work-mesh-source-of-truth
title: Work mesh is the source of truth; MQTT is ids-only doorbells
when: work-mesh || board || project view || listen || mqtt || cache
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 1
created: 2026-08-16
public: true
---

## Rule

Board stories, Status git coordinates, and live agent work come from the work mesh (`GET/PUT /v1/work-mesh/projects/{id}` and work-sessions), not from HQ sync or local `prd.json`.

MQTT carries **ids-only** doorbells on personal topics `hq/{prs_*|agt_*}/{dm,work,sessions,notifications}`. Clients refetch into `~/.hq/work-mesh/cache/` and render that cache.

`work-mesh listen` is the cache writer. Desktop, web, and local agent sessions are cache readers. Do not put message bodies on MQTT. Do not overwrite `hq-agent/core` or cloud-init user-data to install listen — use `~/.hq/work-mesh/`.
