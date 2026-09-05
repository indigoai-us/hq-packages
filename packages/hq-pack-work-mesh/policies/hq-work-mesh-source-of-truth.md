---
id: hq-work-mesh-source-of-truth
title: Work mesh is the source of truth; MQTT is ids-only doorbells
when: work-mesh || board || project view || mesh daemon || mqtt || cache
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 2
created: 2026-08-16
updated: 2026-09-04
public: true
---

## Rule

Board stories, Status git coordinates, and live agent work come from the work mesh (`GET/PUT /v1/work-mesh/projects/{id}`, `/v1/work-mesh/session-events`, `/v1/work-mesh/live`), not from HQ sync or local `prd.json`.

MQTT carries **ids-only** doorbells and retained presence. The resident process is **`hq mesh daemon`** (hq-cli). The pack `listen` / `watch` verbs are removed as of 0.2.0.

Do not put message bodies, prompts, transcripts, tokens, or credentials on MQTT or in spool lines. Do not overwrite `hq-agent/core` or cloud-init user-data.
