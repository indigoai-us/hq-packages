# Changelog

## 0.2.0 — 2026-09-04

- **Breaking:** removed `listen` and `watch` verbs from `hq-work-mesh.mjs`.
  Presence, spool flush, and MQTT are owned by **`hq mesh daemon`** (hq-cli).
  Install with `hq mesh daemon install`; check with `hq mesh daemon status`.
- Deleted `scripts/install-listen.sh` and `hooks/SessionStart/60-work-mesh-bin.sh`.
- `apply.sh` no longer installs the isolated `~/.hq/work-mesh/bin` listen
  daemon. On apply it idempotently unloads and removes the legacy LaunchAgent
  `ai.getindigo.hq-work-mesh-listen` (and clears a leftover Linux listen pidfile).
- Package still provides genesis (`hq-work-mesh-genesis.sh`), doctor, and Board
  story helpers; docs and the skill point operators at the new CLI verbs.

## 0.1.5 — 2026-08-17

- `apply.sh` now inserts `/prd` Step 5.6b (work-mesh genesis) into local
  PRD skills. Install no longer leaves genesis as a human leftover.
- Published on git at `github:indigoai-us/hq-packages#packages/hq-pack-work-mesh`
  (still `private` on npm).

## 0.1.4 — 2026-08-17

- `install-listen.sh` is no longer macOS-only. Linux agent boxes get the
  Deacon path: npm `mqtt` client under `~/.hq/work-mesh/runtime` plus a
  detached `nohup node …/work-mesh.mjs listen`. No broker to install.
  SessionStart restarts Linux listen from the pidfile after a reboot.

## 0.1.3 — 2026-08-16

- Doctor warms 1:1 DMs into the machine cache: `GET /v1/notify/inbox`,
  contacts, and pair threads under `cache/inbox`, `cache/contacts`,
  `cache/dms/{personUid}.json`. Channel-directory warm never included pair
  DMs, so chats like Jacob today never landed on disk.
- Listen doorbells with `scope: dm` refresh the inbox cache the same way.

## 0.1.2 — 2026-08-16

- Doctor warms the directory snapshot plus DM/chat message windows (Slack-like cache).
- `--apply` sends `lastActivityAt` from the newest local project date (prd/mtime/genesis), not now.

## 0.1.1 — 2026-08-16

- `work-mesh doctor` — audit local cloud-backed projects against the mesh, warm `~/.hq/work-mesh/cache` from GET (no doorbells), `--apply` repairs missing/stale views with paced PUTs so onboarding cannot flood `/work`.

## 0.1.0 — 2026-08-16

Dogfood pack so a local HQ can join the work mesh before this lands in hq-core.

- Isolated helper at `~/.hq/work-mesh/bin` (survives `/update-hq`)
- `hq install ./packages/source/hq-pack-work-mesh` + `apply.sh`
- `listen` cache writer; genesis + story PATCH helpers
- SessionStart hook heals a missing isolated bin
- Does not overwrite `hq-agent` or cloud-init user-data
