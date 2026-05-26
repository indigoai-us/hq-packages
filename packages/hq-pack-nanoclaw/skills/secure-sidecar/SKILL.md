---
name: secure-sidecar
description: Author a secure capability-bridge sidecar — expose a sensitive local tree (repo, knowledge base, agent workspace, config store) to a remote chat access point (Telegram, Slack, CLI) as a named-capability dispatcher, never a remote shell. Use when building remote access to a sensitive local tree, adding a chat bridge to a local agent, designing a confirmation-gated mutation flow, or hardening an existing sidecar. Covers allowlist roots, deny lists, confirmation-gated writes, append-only audit, and a fixture smoke harness.
---

# Secure Capability-Bridge Sidecar

Build a sidecar that lets a trusted person reach a sensitive local tree from a remote chat surface **without** turning that surface into remote shell access to the host.

The non-negotiable rule: **the bridge is a dispatcher over named capabilities, not a command interpreter.** Messages are classified into a fixed set of known capabilities. Anything that does not classify is refused with a short explanation of the boundary. The agent never gets to choose an arbitrary file path, run a shell command, or read a credential.

This skill is an authoring guide. The reference implementation and templates it points to live in the companion knowledge directory (`core/knowledge/public/secure-sidecar/` after install, or `knowledge/secure-sidecar/` in this pack's source).

## When to use this

- Adding remote (Telegram / Slack / SMS / email / CLI) access to a local agent or workspace.
- Exposing read access to a sensitive tree (source repo, private knowledge base, project state) to a phone or chat client.
- Designing a confirmation-gated write flow where a remote caller can queue low-risk actions but cannot mutate freely.
- Hardening or reviewing an existing sidecar that has started to feel like a remote shell.

## The seven boundary layers

A secure sidecar is defined by seven layers. Decide each one explicitly before writing code; record your decisions in a threat-model doc (copy `threat-model-template.md`).

1. **Ingress** — which channel(s) deliver requests. Pick one to start (e.g. Telegram). A local CLI path is useful as a credential-free smoke surface but is not a remote-identity boundary.
2. **Identity** — a request is trusted only after a concrete paired identity matches (e.g. Telegram chat id + sender id). Unpaired traffic is dropped *before* any sensitive context is loaded.
3. **Agent context** — requests land in a dedicated, constrained context that does not inherit broad assistant behavior (web browsing, shell, scheduling, repo edits). See `config/group-blueprint.example.yaml`.
4. **Capability bridge** — the dispatcher. Named handlers only; unknown requests refused. This is `reference/capability-bridge.ts`.
5. **Mount / allowlist boundary** — only specific named roots are reachable, each justified by a capability. Never mount the tree root. See `config/allowlist.example.json`.
6. **Confirmation flow** — read capabilities run directly; mutations require an exact confirmation phrase and write only to one named scope.
7. **Audit log** — every request (allowed / completed / denied / failed) is appended to a JSONL log the agent cannot rewrite.

## Step-by-step

### 1. Define the allowlist config

Copy `config/allowlist.example.json` and enumerate the narrow roots your capabilities need, each with a read or read-write access mode plus blocked patterns. The rule: list paths, not the root. Adding a new path later requires naming the capability, the access mode, and the denial behavior that justify it.

### 2. Wire the read-only capability dispatcher

Copy `reference/capability-bridge.ts`. It is standalone and config-driven — pass it your allowlist, denied path patterns, and denied action words; do not hardcode tree-specific paths. The reference ships three generic read capabilities (`read_status`, `lookup`, `search`); rename or extend them for your domain, but keep the load-bearing safety machinery intact:

- `isAllowedResolvedPath` — resolves a candidate path and checks it is inside an allowlisted root and not denied. Every read goes through it.
- `matchesDeniedPath` — defense in depth: a denied path is rejected even if it somehow appears inside an allowed root.
- `classifyDenial` — rejects denied **action words** (shell, exec, deploy, publish, commit, push, install, curl, …) and denied **paths** named in the request, before any file access.
- `sanitizePathSegment` — request-supplied names must be plain safe segments (no traversal).
- File-size caps and a bounded search walk — avoid reading huge files or unbounded traversal.

### 3. Add the confirmation-gated mutation envelope

Mutations are a tiny allowlist (the reference ships one: `create_record`). Each:

- Builds a **pending envelope** first: `{ capability, summary, targetScope, affectedPaths, riskLevel, confirmationPhrase }`. Nothing is written.
- The sidecar sends the summary, affected paths, and exact confirmation phrase to the trusted caller.
- Only an exact phrase match triggers execution. Cancelled, expired, mismatched, missing, or edited confirmations are denied and logged.
- The write targets exactly one named scope and is asserted to stay inside it (`assertMutationTarget`). It writes a request record — it does not execute shell, edit repos, call external APIs, or deploy.

### 4. Wire the append-only audit log

Every call to the bridge appends one JSON line: timestamp, requester, channel, capability, scope, confirmation state, outcome, files read, files written, denial reason. Append-only so smoke tests can assert outcomes without parsing chat transcripts, and so the agent cannot rewrite history.

### 5. Write the fixture smoke harness

Copy `reference/smoke-harness.ts`. It builds a temporary fixture tree, runs the safety-critical paths, and asserts outcomes + audit entries with no real secrets and no running daemon:

| Step | Expected outcome | Safety assertion |
|---|---|---|
| allowed read | `allowed` | reads only allowlisted files |
| scoped search | `allowed` | searches only the explicit scope |
| pending mutation | `allowed` | returns an envelope, writes nothing |
| confirmed mutation | `completed` | writes exactly one record in the named scope |
| denied action (e.g. shell) | `denied` | reads nothing, writes nothing |

Run it: `npx tsx reference/smoke-harness.ts` (or `bun reference/smoke-harness.ts`). Treat a failure as a release blocker.

## Security checklist (must all hold)

- [ ] Bridge classifies into named capabilities; unknown → refused.
- [ ] Allowed roots are an explicit allowlist; the tree root is never mounted.
- [ ] Deny list (credentials, shell rc files, secrets, broad source/knowledge roots) enforced even inside allowed roots.
- [ ] Denied action words rejected before any file access.
- [ ] Mutations are a tiny allowlist, each gated by an exact confirmation phrase, writing only to one named scope.
- [ ] Append-only audit entry for every request, including denials and failures.
- [ ] Identity paired before sensitive context loads; unpaired traffic dropped.
- [ ] Fixture smoke harness passes (allowed / scoped / pending / confirmed / denied + audit).

## Stop conditions — redesign before continuing

If any of these become necessary, the sidecar shape has ended. Stop and design a native gateway that owns identity, capability routing, confirmation state, audit, and credentials inside the host system itself:

- Mounting the tree root, all of a broad source/knowledge root, or arbitrary worktrees.
- Running arbitrary shell commands from chat.
- Letting the agent choose filesystem paths outside a capability's declared scope.
- Granting write access to repos, settings, credentials, deploy targets, or external API clients.
- Adding more channels before identity, revocation, audit, and offline behavior are solid.
- Depending on prompt instructions instead of explicit handler checks for denial behavior.

## Reference files

- `pattern.md` — the full generalized pattern and rationale.
- `threat-model-template.md` — copy and fill in `<sensitive-tree>` / `<allowed-roots>` placeholders.
- `reference/capability-bridge.ts` — config-driven dispatcher.
- `reference/smoke-harness.ts` — fixture smoke.
- `config/allowlist.example.json`, `config/group-blueprint.example.yaml` — example configs.
