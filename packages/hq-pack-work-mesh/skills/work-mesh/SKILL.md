---
name: work-mesh
description: Work Mesh Live — automatic presence via hq mesh daemon; enqueue-only hooks; manual task-status/blocked/note. Use when installing the daemon, reconciling session context, or recording Board signals.
---

# Work mesh

Presence and per-turn activity are **automatic**. Hooks append to
`~/.hq/work-mesh/spool.jsonl`; **`hq mesh daemon`** resolves context, flushes
batches, and publishes MQTT presence. Do not install the deleted pack
`listen` / `watch` path.

## Install / upgrade

```bash
bash core/packages/hq-pack-work-mesh/scripts/apply.sh   # genesis + unload legacy listen
hq mesh daemon install
hq mesh daemon status
```

`apply.sh` removes LaunchAgent `ai.getindigo.hq-work-mesh-listen` if present.
Never overwrite `hq-agent/core` or cloud-init user-data.

## CLI verbs (hq-cli)

```bash
# Daemon (one per machine)
hq mesh daemon install | status | doctor | uninstall
hq mesh daemon run          # foreground

# Session (hooks enqueue most kinds; agents use these for Board signals)
hq mesh session task-status --session <sid> --enqueue --seq <n> --task-id <id> --status queued|in_progress|review|done
hq mesh session blocked --session <sid> --enqueue --seq <n> --reason "<short>"
hq mesh session note --session <sid> --enqueue --seq <n> --summary "<<=280 chars>"
hq mesh session flush

# Context
hq mesh context reconcile --session <sid>
hq mesh context default get|set|clear
hq mesh context untracked <sessionId>
hq mesh context organize --session <sid> --decision <id> --option <id>
```

## Genesis (this pack)

```bash
bash core/scripts/hq-work-mesh-genesis.sh --company <slug> <project>
```

`apply.sh` inserts `/prd` Step 5.6b so cloud-backed `/prd` runs genesis after
board upsert (policy `hq-work-mesh-prd-genesis`).

## Rules

- MQTT and events are metadata-only. Never put prompts, transcripts, tokens, or credentials on the wire or in spool lines.
- Tenant isolation: verified company binding only; `needs_company` / `company_conflict` stay local until resolved.
- Manual verbs only: `task-status`, `blocked`, `note`. Do not call deleted `work-mesh.sh listen|watch|start|progress`.
