# Issue orchestrator architecture

The pack separates policy from adapters. One tenant-scoped configuration defines the agent, goals, source contracts, lifecycle, scope, permissions, handoff, schedule, and pilot state. Source-specific tools only collect and optionally apply an explicitly permitted action.

The manager owns a durable lifecycle:

`collect -> normalize -> exact dedupe -> classify -> plan -> act if permitted -> hand off -> checkpoint`

Every item retains its source-native identity and canonical link. Similarity matches are reversible groupings, not destructive merges. Writes are individually gated. Terminal resolution always requires an authorized human signal.

Shepherd's Indigo feedback manager is the reference pattern: one durable queue, exact replay safety, canonical-thread communication, bounded work leases, explicit human completion, independent write gates, health reporting, and a read-only canary before activation. Its company-specific Slack channel, repository allowlist, GitHub App, board, and systemd deployment are examples, not defaults in this pack.
