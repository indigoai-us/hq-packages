# Issue orchestrator operations

Start in pilot mode with a sample of five or fewer items and one concurrent work slot. Review inclusions, exclusions, dedupe, routing, ownership, proposed actions, and handoff quality before activation.

Activate permissions independently. Reading a queue does not authorize commenting. Commenting does not authorize status changes. Draft changes do not authorize merge or deployment. Resolution remains human-controlled.

A durable runner must expose last start, last success, last failure, phase checkpoints, counts, stale age, source probes, and pending human decisions. Use an approved HQ schedule or host service. Avoid cron, terminal loops, and session-scoped watchers for persistent operation.

Rollback must independently pause collection, disable communication, disable ticket or repository writes, and retain the audit trail and last known report.
