# hq-pack-work-mesh

Upgrade a local HQ so it works with the live work mesh — without waiting for hq-core promotion.

Installs the listen cache service, genesis on `/prd`, Board/Status snapshot helpers, and an isolated agent-box listener. MQTT stays ids-only. Apps and agents read `~/.hq/work-mesh/cache/`.

## Install (another HQ / teammate)

From the HQ root:

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-work-mesh --allow-hooks
bash core/packages/hq-pack-work-mesh/scripts/apply.sh
```

Git install (no npm). `private: true` on purpose: this pack stays off the public npm feed until it is promoted into hq-core.

`hq install` copies the pack into `core/packages/hq-pack-work-mesh/` and runs `scan-packages.sh` (skills, command, policies, namespaced scripts). `apply.sh` then drops the isolated helper at `~/.hq/work-mesh/bin` so `/update-hq` cannot roll listen back to a July `core/scripts/work-mesh.sh`.

On a local dogfood tree that already symlinks `packages/source/hq-pack-work-mesh`, just run `apply.sh` after you edit it. Do **not** re-run `hq install` there; it would replace the symlink with a copy.

On an **agent box** (no desktop MQTT):

```bash
bash core/packages/hq-pack-work-mesh/scripts/install-listen.sh
```

That installs the npm `mqtt` **client** under `~/.hq/work-mesh/runtime` and detaches listen (LaunchAgent on macOS, nohup on Linux). Do not install a broker. Deacon is this same path: `node ~/.hq/work-mesh/bin/work-mesh.mjs listen` as `ec2-user`.

Skip `install-listen` on a Mac that already runs HQ desktop MQTT. Two cache writers will fight. Pass `--force` only if you mean to replace an isolated listen you own.

`apply.sh` / `install-listen.sh` never overwrite `hq-agent/core` or cloud-init user-data.

## After install

```bash
# New project → mesh thread + channel + Board snapshot
bash core/scripts/hq-work-mesh-genesis.sh --company indigo my-project

# Local mesh doctor (audit + warm cache; no doorbells)
bash ~/.hq/work-mesh/bin/work-mesh.sh doctor --company indigo
# Repair missing/stale views, paced so we do not flood /work
bash ~/.hq/work-mesh/bin/work-mesh.sh doctor --company indigo --apply --limit 20

# Story status
bash ~/.hq/work-mesh/bin/work-mesh.sh story --company indigo --project my-project --story US-001 --status in_progress

# Cache writer (agent boxes; already started by install-listen)
tail -f ~/.hq/work-mesh/logs/listen.log
```

`apply.sh` inserts `/prd` Step 5.6b (work-mesh genesis) into the local PRD skill (`.agents`, `.claude`, `personal`). Cloud-backed `/prd` then runs `hq-work-mesh-genesis.sh` after board upsert. Re-running apply is a no-op when the step is already present. Policy `hq-work-mesh-prd-genesis` is the same rule.

## Layout

```
packages/hq-pack-work-mesh/
├── package.yaml
├── README.md
├── skills/work-mesh/SKILL.md
├── commands/work-mesh.md
├── hooks/SessionStart/60-work-mesh-bin.sh
├── policies/
├── knowledge/work-mesh/
└── scripts/
    ├── hq-work-mesh.sh / .mjs    # listen + start/progress/story
    ├── genesis.sh
    ├── hq-work-mesh-genesis.sh   # namespaced scan-packages entry
    ├── install-listen.sh
    ├── apply.sh
    └── lib/install-isolated-bin.sh
```

Isolated machine layout:

```
~/.hq/work-mesh/
  bin/work-mesh.sh      # wrapper → work-mesh.mjs
  bin/work-mesh.mjs
  bin/genesis.sh
  runtime/node_modules/mqtt
  cache/                # hot window, not Slack history
  logs/listen.log
```

## Dogfood vs hq-core

This pack is the rollout vehicle. After Indigo field-test, promote the helper into hq-core `core/scripts/work-mesh.*` and either retire the pack or keep it as a thin install wrapper for older trees. Do not publish to npm until that promotion is an explicit decision.
