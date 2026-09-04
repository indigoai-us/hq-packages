# hq-pack-work-mesh

Dogfood pack for Work Mesh genesis and Board helpers. **0.2.0** removes the
legacy `listen` / `watch` cache daemon. Presence and spool flush live in
**hq-cli**:

```bash
hq mesh daemon install
hq mesh daemon status
hq mesh daemon doctor
```

## Install

From the HQ root:

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-work-mesh --allow-hooks
bash core/packages/hq-pack-work-mesh/scripts/apply.sh
hq mesh daemon install
```

`apply.sh` wires genesis into local PRD skills and **unloads/removes** any
legacy LaunchAgent `ai.getindigo.hq-work-mesh-listen`. It does **not** install
`~/.hq/work-mesh/bin` or start a Node listen process.

## After install

```bash
# New project → mesh thread + channel + Board snapshot
bash core/scripts/hq-work-mesh-genesis.sh --company indigo my-project

# Manual session signals (presence/turns are automatic via hooks + daemon)
hq mesh session task-status --session-id <sid> --enqueue --seq <n> --task-id US-001 --status in_progress
hq mesh session blocked --session-id <sid> --enqueue --seq <n> --reason "waiting on design"
hq mesh session note --session-id <sid> --enqueue --seq <n> --summary "shipped card coalescing"

# Context
hq mesh context reconcile --observation-file <path>
hq mesh context organize --session <sid> --decision <id> --option <id>
```

## Layout

```
packages/hq-pack-work-mesh/
├── package.yaml          # 0.2.0 — no SessionStart listen heal hook
├── README.md
├── skills/work-mesh/SKILL.md
├── commands/work-mesh.md
├── policies/
├── knowledge/work-mesh/
└── scripts/
    ├── hq-work-mesh.sh / .mjs    # check/start/progress/story/doctor (no listen/watch)
    ├── genesis.sh
    ├── hq-work-mesh-genesis.sh
    ├── apply.sh                  # unload legacy listen; no isolated-bin install
    └── lib/
```

## Dogfood vs hq-core

Promote genesis and docs into hq-core after field-test. The resident process is
always `hq mesh daemon`, never a pack-owned Node listen.
