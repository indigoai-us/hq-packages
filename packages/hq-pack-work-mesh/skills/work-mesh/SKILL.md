---
name: work-mesh
description: Live work-mesh layer — register project work, report progress, listen for ids-only MQTT doorbells, and keep ~/.hq/work-mesh/cache warm. Use when starting project work, updating Board story status, installing listen, or reading the machine cache for project knowledge.
---

# Work mesh

The mesh is the source of truth for project Board/Status and live agent work. MQTT carries **ids-only** doorbells. Apps and agents read the machine cache.

## Install / upgrade this HQ

```bash
hq install ./packages/source/hq-pack-work-mesh --allow-hooks   # other HQ trees
bash core/packages/hq-pack-work-mesh/scripts/apply.sh          # isolated ~/.hq/work-mesh/bin
# Agent box only (skip when desktop MQTT already writes the cache):
bash core/packages/hq-pack-work-mesh/scripts/install-listen.sh
```

Never overwrite `hq-agent/core` or cloud-init user-data. Isolated listen lives at `~/.hq/work-mesh/`.

**MQTT is a client, not a broker.** `install-listen.sh` npm-installs the `mqtt` package into `~/.hq/work-mesh/runtime` and starts a detached `node …/work-mesh.mjs listen` that connects outbound to AWS IoT Core. Do not install mosquitto. Do not keep listen in the agent job — the dispatch watchdog kills in-session sockets (~300s idle / 900s absolute). Linux uses nohup + pidfile (Deacon pattern). macOS uses a LaunchAgent. Verify with `pgrep -af 'work-mesh.mjs listen'` and `tail ~/.hq/work-mesh/logs/listen.log`. `doctor --cache-only` on a timer is a fallback, not a substitute.

## Agent / operator verbs

```bash
# Isolated helper (survives /update-hq)
bash ~/.hq/work-mesh/bin/work-mesh.sh start --company <slug|cmp_*> --project <slug> --summary "…"
bash ~/.hq/work-mesh/bin/work-mesh.sh progress --company … --project … --summary "…"
bash ~/.hq/work-mesh/bin/work-mesh.sh story --company … --project … --story US-001 --status in_progress
bash ~/.hq/work-mesh/bin/work-mesh.sh listen --cache-file ~/.hq/work-mesh/live-cache.json

# New / existing HQ project → mesh thread + invite-only channel + PROJECT_VIEW
bash core/scripts/hq-work-mesh-genesis.sh --company <slug> <project>

# Local mesh doctor — populate + align without a doorbell storm
bash ~/.hq/work-mesh/bin/work-mesh.sh doctor --company <slug>
bash ~/.hq/work-mesh/bin/work-mesh.sh doctor --company <slug> --apply
```

`apply.sh` inserts `/prd` Step 5.6b so cloud-backed `/prd` runs genesis after board upsert (policy `hq-work-mesh-prd-genesis`).

## Doctor (onboarding + anytime audit)

Default is **audit + cache warm**: GET each local project view, write `~/.hq/work-mesh/cache`, report missing/stale. No PUT, so no `/work` doorbells.

`--apply` repairs gaps, **paced** (default 2500ms + 0–500ms jitter between mutations). It only PUTs when the mesh is missing the project or is missing stories/repos that local `prd.json` has. Live Board story status is never overwritten from local prd.

`--cache-only` skips planning PUTs. `--limit N` is the safe first run. Never auto-run from SessionStart.

Doctor always warms `cache/directory/{prs_*}.json` (project + group channels), channel message windows, **and** 1:1 DMs (`cache/inbox`, `cache/contacts`, `cache/dms/{personUid}.json`). Pair DMs are not in the channel directory. Project boards stay under `cache/projects/`. `--apply` sets channel `lastActivityAt` from the newest local project date (prd/mtime/genesis), not wall-clock now.

## Cache (hot window, not Slack history)

```
~/.hq/work-mesh/cache/
  projects/{companyUid}/{projectId}.json
  channels/{channelId}.json
  directory/{principalUid}.json
  inbox/{principalUid}.json
  contacts/{principalUid}.json
  dms/{personUid}.json
  sessions/{companyUid}/{projectId}.json
```

Local sessions should read these files for rapid project knowledge. Listen keeps them warm from doorbells.

## Rules

- MQTT is ids-only. Never put message bodies on the wire.
- Tenant isolation: only the active company's `cloudCompanyUid` and credentials.
- Isolated listen only on agent boxes. Do not mutate user-data.
