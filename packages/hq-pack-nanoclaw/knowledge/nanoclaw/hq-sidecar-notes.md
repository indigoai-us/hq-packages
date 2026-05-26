# NanoClaw HQ-Sidecar — Spike Notes

These notes capture what a NanoClaw "HQ sidecar" spike proved, and why the durable, reusable artifact is the **secure capability-bridge pattern** (`../secure-sidecar/pattern.md`) rather than the spike's host-specific wiring.

## What the spike asked

Can a trusted owner reach useful local context — status, project lookups, handoff summaries, scoped search — from a chat access point (Telegram) **without** granting remote shell access to the machine?

## What it proved

Yes, when access stays **capability-scoped**. A surprisingly useful surface fits inside tight constraints: status summaries, scoped lookups, scoped search, and tiny confirmation-gated request records. None of that required mounting the tree root, running arbitrary commands, or reading credentials.

The safe shape that emerged:

- A **dedicated, constrained agent group** (not the general-purpose assistant) — no web, no shell, no repo edits, no deploys.
- A **read-only capability dispatcher** over named handlers — never a command interpreter.
- An **explicit mount allowlist** — narrow named paths, never the tree root.
- A **deny list** enforced even inside allowed roots (credentials, shell rc files, secrets, broad source/knowledge roots).
- **Confirmation-gated mutations** — a tiny allowlist, each requiring an exact phrase, writing only request records to one scope.
- An **append-only audit log** the agent can't rewrite.
- **Paired identity** (chat id + sender id) checked before any context loads.

## Why the wiring was throwaway but the pattern graduated

The spike's security boundary was split awkwardly across NanoClaw group prompts, host-specific bridge code, mount config, and host process knowledge. Those pieces are tied to one host and one channel. The **pattern** — dispatcher-not-interpreter, allowlist + deny + confirm + audit, paired identity — is host-agnostic and is the part worth reusing.

That generalized pattern, plus a config-driven reference implementation and a fixture smoke harness, lives in this pack at `../secure-sidecar/`. Start there to build a sidecar; use NanoClaw (via `/setup-nanoclaw`) as a ready-made container-isolated ingress for it.

## Stop conditions (carry these forward)

If a sidecar starts needing broad mounts, arbitrary command execution, agent-chosen paths outside a capability scope, write access to repos/credentials/deploys, or more channels before identity+audit are solid — stop and design a native gateway that owns identity, capability routing, confirmation state, audit, and credentials inside the host system itself. The moment a sidecar needs broad mounts or command execution, it has stopped being a sidecar.
