# NanoClaw — Architecture Overview

[NanoClaw](https://github.com/nanocoai/nanoclaw) is a small, container-isolated personal Claude assistant — an intentionally minimal runtime that connects messaging channels (Telegram, Slack, Discord, WhatsApp, iMessage, email, …) to Claude agents, where each agent runs inside its own Linux container and can only touch what you explicitly mount. Built on the Claude Agent SDK + Claude Code. Host is TypeScript/Node; the container agent runs on Bun. Philosophy: *customization is code changes, not config files.*

This doc is a condensed reference for HQ users. The authoritative docs live in the NanoClaw repo (`README.md`, `CLAUDE.md`, `docs/`).

## Message flow

```
messaging apps → host (router) → inbound.db → container (Bun + Claude Agent SDK)
              → outbound.db → host (delivery) → messaging apps
```

A single Node host process orchestrates per-session Docker containers. **Everything is a message** — there is no IPC, no file watcher, no stdin piping between host and container. Two SQLite files per session are the sole IO surface.

## Entity model

```
users  →  messaging_groups  ↔  agent_groups  →  sessions
```
- **users** — platform identities (`<channel>:<handle>`), with owner/admin roles (global or scoped).
- **messaging_groups** — one chat/channel on one platform.
- **agent_groups** — a workspace + memory + CLAUDE.md + personality + container config. Wired many-to-many to messaging groups.
- **sessions** — a per-(agent_group × messaging_group) container.

Privilege is user-level (owner/admin), not agent-group-level. Three isolation levels exist (`agent-shared`, `shared`, separate agents).

## Two-DB session split

Each session has two SQLite files: `inbound.db` (host writes, container reads) and `outbound.db` (container writes, host reads). Exactly one writer per file → no cross-mount lock contention. A central `data/v2.db` holds everything not per-session (users, roles, agent_groups, messaging_groups, wiring).

## Channels & providers are skill-installed

Trunk ships only the registry/infra. Specific channel adapters (Telegram, Slack, …) live on a long-lived `channels` branch; non-default agent providers (e.g. OpenCode) on a `providers` branch. Each `/add-<name>` skill is idempotent: fetch the branch → copy the module → wire a self-registration import → install a pinned dep → build.

## Credentials (OneCLI)

API keys and OAuth tokens are managed by the OneCLI gateway and injected into containers at request time — never passed in env vars or chat context. The container learns this via the `onecli-gateway` container skill.

## Admin CLI (`ncl`)

`ncl <resource> <verb>` manages the central DB — agent groups, messaging groups, wirings, users, roles, members, destinations, sessions. On the host it connects via Unix socket; inside containers via the session DB transport.

## Setup & maintenance

- **Install** — `bash nanoclaw.sh` (interactive: deps, container image, OneCLI vault, Anthropic credential, service, first agent, channel wiring). In HQ, start with `/setup-nanoclaw`.
- **Update** — `/update-nanoclaw` (low-token upstream merge sync) or `/migrate-nanoclaw` (intent-based replay upgrade for heavy forks). See `maintenance.md`.

## Why this matters for the secure-sidecar pattern

NanoClaw's container isolation + channel adapters make it a natural **ingress** for a secure capability-bridge sidecar: a paired channel identity delivers requests, and a constrained agent group dispatches only named capabilities against an allowlisted local tree. See `hq-sidecar-notes.md` and `../secure-sidecar/pattern.md`.
