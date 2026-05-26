# hq-pack-nanoclaw

The NanoClaw integration pack for HQ. It bootstraps a local NanoClaw install, gives you HQ-discoverable maintenance entrypoints, and bundles the secure capability-bridge sidecar pattern for safe remote access to a sensitive local tree.

[NanoClaw](https://github.com/nanocoai/nanoclaw) is a small, container-isolated personal Claude assistant — messaging channels (Telegram, Slack, …) connect to Claude agents that each run in their own Linux container, so an agent can only touch what you explicitly mount.

This pack does **not** vendor the NanoClaw app. `/setup-nanoclaw` clones it from the upstream repo and runs its own installer; the maintenance skills operate on that cloned checkout. That keeps the app on its native install/update path and keeps this pack thin.

## What this pack adds

| Skill | Purpose |
|---|---|
| `/setup-nanoclaw` | Clone NanoClaw into your HQ `repos/`, run its setup, register it in `companies/manifest.yaml`. |
| `/update-nanoclaw` | HQ-adapted low-token upstream sync (preview → backup → merge/cherry-pick/rebase → validate), targeting your cloned checkout. |
| `/migrate-nanoclaw` | HQ-adapted intent-based upgrade (extract customizations → replay on clean upstream in a worktree), targeting your cloned checkout. |
| `/secure-sidecar` | Authoring guide for a secure capability-bridge sidecar — expose a sensitive local tree to a remote chat surface as a named-capability dispatcher, never a remote shell. |

| Knowledge | Contents |
|---|---|
| `nanoclaw/` | Architecture overview, the migrate-vs-update maintenance methodology, and HQ-sidecar spike notes. |
| `secure-sidecar/` | The pattern writeup, a fill-in threat-model template, a config-driven reference implementation + fixture smoke harness, and example configs. |

The pack ships **no hooks** and **no scripts**, so installing it never prompts for hook confirmation and never wires anything into your live tooling.

## Install

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-nanoclaw   # git (no auth)
hq install ./packages/hq-pack-nanoclaw                                # local path (dev)
```

## Typical flow

1. `hq install …#packages/hq-pack-nanoclaw`
2. `/setup-nanoclaw` — clones NanoClaw and walks you through `bash nanoclaw.sh` (interactive: deps, container image, credential vault, service, first agent, channel wiring — run it in a terminal, not inside Claude Code).
3. Day-to-day inside the cloned repo: wire channels and customize using NanoClaw's own in-repo skills.
4. `/update-nanoclaw` or `/migrate-nanoclaw` from HQ to pull upstream changes into your checkout.
5. `/secure-sidecar` when you want NanoClaw (or any runtime) to reach a sensitive local tree from a remote chat surface safely.

## Notes on the maintenance skills

`/update-nanoclaw` and `/migrate-nanoclaw` are HQ-adapted versions of NanoClaw's own upgrade skills. Differences from the in-repo originals:

- They resolve a `NANOCLAW_DIR` (default `repos/public/nanoclaw`) and run every git/build/service command against **that** checkout, so they are safe to invoke from an HQ session.
- Repo-local follow-up skills (`/update-skills`, `/add-<channel>`) are run from inside the NanoClaw checkout's own Claude session, not from HQ.
- The upstream telemetry (PostHog phone-home) has been removed.

## License

MIT.
