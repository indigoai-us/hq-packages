# The Secure Capability-Bridge Sidecar Pattern

A sidecar lets a trusted person reach a sensitive local tree — a source repository, a private knowledge base, an agent workspace, a config store — from a remote chat surface (Telegram, Slack, SMS, email, a local CLI). The danger is obvious: a naive bridge becomes remote shell access to the host. This pattern is the safe shape that avoids that.

It was extracted from a working spike (a NanoClaw "HQ sidecar" that let a trusted owner query a local HQ install over Telegram). The host-specific wiring from that spike was deliberately discarded; what follows is the reusable security shape.

## Core principle: dispatcher, not interpreter

The bridge classifies an incoming message into one of a fixed set of **named capabilities**. A message that does not classify is refused with a short explanation of the boundary. The agent never gets to:

- run a shell command or command fragment,
- choose an arbitrary filesystem path,
- read a credential, secret, or key,
- mutate anything outside a tiny confirmation-gated allowlist.

Everything else in this document is in service of that principle.

## The capability model

Two tiers of capability.

**Read-only capabilities** run directly (no confirmation) but still write an audit entry. The reference ships three generic ones:

| Capability | Allowed scope | Notes |
|---|---|---|
| `read_status` | newest files under one configured status root | parsed summaries, not raw dumps |
| `lookup` | a named record under an allowed root | request name must be a safe path segment |
| `search` | one explicit allowlisted scope | scope must be named by the caller and allowlisted |

Rename or extend these for your domain (e.g. `project_lookup`, `board_lookup`) — but keep them read-only and keep them scoped.

**Confirmation-gated mutations** are a tiny allowlist. The reference ships one: `create_record`, which writes a single JSON request record to one named scope. A mutation:

1. First returns a **pending envelope** — `{ capability, summary, targetScope, affectedPaths, riskLevel, confirmationPhrase }` — and writes nothing.
2. The sidecar sends the summary, affected paths, and exact confirmation phrase to the trusted caller.
3. Only an exact phrase match executes it. Cancelled / expired / mismatched / missing / edited confirmations are denied and logged.

A mutation writes a *request record*. It does not execute shell, edit repos, call external APIs, deploy, or change settings. Those are not sidecar capabilities — they are stop conditions (see below).

## Defense in depth: three independent gates

Safety does not rely on any single check. A request passes only if all three gates allow it.

### Gate 1 — denied actions (before any file access)

`classifyDenial` rejects the request if the capability/action text contains a denied **action word**: `shell`, `command`, `exec`, `bash`, `terminal`, `deploy`, `publish`, `commit`, `push`, `merge`, `rebase`, `install`, `curl`, and the like. This runs first, so a request that even *names* a forbidden action never reaches the filesystem.

### Gate 2 — denied paths (allowlist + deny list)

Two complementary checks:

- **Allowlist** (`isAllowedResolvedPath`): every path is resolved to an absolute path and must be inside one of the explicit allowed roots. The tree root is never an allowed root. Path traversal (`..`) resolves out and is rejected.
- **Deny list** (`matchesDeniedPath`): even inside an allowed root, a path matching a denied pattern (credential paths, shell rc files, `secret`, `token`, `credential`, `.env`, `.ssh`, `.aws`, broad source/knowledge roots) is rejected. This is the belt-and-suspenders: a denied path should be absent from the allowlist *and* still rejected by name.

Caller-supplied names are passed through `sanitizePathSegment` — they must be plain `[A-Za-z0-9._-]` segments, so a request can never smuggle a traversal or an absolute path.

### Gate 3 — confirmation (for mutations only)

A mutation executes only on an exact confirmation-phrase match. The write target is re-asserted to be inside the configured mutation scope (`assertMutationTarget`) and to end in `.json`, so even a malformed envelope cannot escape the scope. The file is written with the `wx` flag (fail if exists), so a mutation can never overwrite.

## Append-only audit log

Every request — `allowed`, `completed`, `denied`, or `failed` — appends exactly one JSON line to a log the agent cannot rewrite. Each entry records:

- timestamp,
- requester identity and channel,
- capability name (after classification),
- scope and affected paths,
- confirmation state (`none` / `pending` / `confirmed` / `cancelled` / `expired`),
- outcome,
- files read and files written,
- denial reason or error summary.

Append-only JSONL means a smoke test can assert behavior without parsing chat transcripts, and a reviewer can reconstruct exactly what a remote caller did.

## Bounded reads

Reads are bounded to keep a capability from becoming a data-exfiltration channel: a per-file size cap (default 256 KB) and a bounded search walk (stops after roughly `maxResults * 20` candidate files). Large files are refused rather than truncated silently.

## Identity and ingress (outside this module)

The bridge assumes the channel layer has already established a trusted identity. In the spike, Telegram requests were accepted only when both the chat id and sender id matched a paired identity; unpaired traffic was dropped *before* any sensitive context was loaded. A local CLI path is useful as a credential-free smoke surface but is **not** a remote-identity boundary — never treat CLI access as proof of a remote caller.

## What this pattern is good for

A surprisingly useful surface fits inside these constraints: status summaries, scoped lookups, scoped search, and low-risk request records. None of that requires mounting the tree root, running commands, or reading credentials. If your remote needs stay inside that envelope, a sidecar is a fast, safe way to get there.

## Stop conditions

Stop and design a native gateway (one that owns identity, capability routing, confirmation state, audit, and credentials inside the host system itself) before doing any of these:

- mounting the tree root, a broad source/knowledge root, or arbitrary worktrees;
- running arbitrary shell commands from chat;
- letting the agent choose paths outside a capability's declared scope;
- granting write access to repos, settings, credentials, deploy targets, or external API clients;
- adding more channels before identity, revocation, audit, and offline behavior are solid;
- depending on prompt instructions instead of explicit handler checks for denial behavior.

The moment a sidecar needs broad mounts or command execution, it has stopped being a sidecar.

## Reference files

- `reference/capability-bridge.ts` — the config-driven dispatcher implementing all three gates + audit.
- `reference/smoke-harness.ts` — a fixture smoke proving allowed / scoped / pending / confirmed / denied paths + the audit log.
- `threat-model-template.md` — a fill-in boundary doc to record your decisions before you write code.
- `config/allowlist.example.json`, `config/group-blueprint.example.yaml` — example configs.
