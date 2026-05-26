# hq-pack-secure-sidecar

A reference pattern and authoring guide for building a **secure capability-bridge sidecar** — a way to reach a sensitive local tree (a repository, a knowledge base, an agent workspace, a config store) from a remote chat access point such as Telegram, Slack, or a CLI, **without** granting remote shell access to the host.

The core idea: the bridge is a **dispatcher over named capabilities, not a command interpreter**. Remote messages can ask for `read_status`, `lookup`, or `search`; they cannot ask the host to run a shell command, read arbitrary files, or touch credentials. Mutations are limited to a tiny allowlist and require an exact confirmation phrase. Every request — allowed, completed, denied, or failed — is written to an append-only audit log.

This pack generalizes a working spike (a NanoClaw "HQ sidecar" that let a trusted owner query a local HQ install over Telegram). The HQ-specific wiring from that spike is intentionally left behind; what graduates here is the reusable security shape.

## What this pack adds

| Contribution | Path | Purpose |
|---|---|---|
| Skill | `/secure-sidecar` | Authoring guide — walks you through standing up a secure capability bridge in any runtime. |
| Knowledge | `secure-sidecar/` | The pattern writeup, a fill-in threat-model template, a config-driven reference implementation, a fixture smoke harness, and example config files. |

After install, the skill is available as `/secure-sidecar` and the knowledge lands under `core/knowledge/public/secure-sidecar/`.

## Install

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-secure-sidecar   # git (no auth)
hq install ./packages/hq-pack-secure-sidecar                                # local path (dev)
```

This pack ships **no hooks** and **no scripts**, so installing it never prompts for hook confirmation and never wires anything into your live tooling. The reference code is delivered as knowledge you copy into your own project.

## Knowledge layout

```
secure-sidecar/
  pattern.md                       — the generalized capability-bridge pattern
  threat-model-template.md         — fill-in boundary doc (copy, replace placeholders)
  reference/capability-bridge.ts   — standalone, config-driven reference dispatcher
  reference/smoke-harness.ts       — dependency-free fixture smoke (tsx or bun)
  config/allowlist.example.json    — example allowed roots + blocked patterns
  config/group-blueprint.example.yaml — deny-by-default agent-group blueprint
```

## Security checklist (summary)

- The bridge classifies messages into **named capabilities**; unknown requests are refused.
- Allowed file roots are an **explicit allowlist** — never the tree root.
- A **deny list** (credential paths, shell rc files, secrets, broad source/knowledge roots) is enforced even for allowlisted callers (defense in depth).
- Denied **actions** (shell, exec, deploy, publish, git, install, external API mutation) are rejected before any file access.
- Mutations are a tiny allowlist, each gated by an **exact confirmation phrase**, and write only to one named scope.
- Every request produces an **append-only audit entry** (requester, channel, capability, scope, outcome, files read/written, denial reason).
- **Stop conditions** are explicit: if you find yourself needing broad mounts or arbitrary command execution, stop and redesign — the sidecar shape has ended.

See `knowledge/secure-sidecar/pattern.md` and `threat-model-template.md` for the full treatment.

## License

MIT.
