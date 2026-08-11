# Configuration contract

Write one JSON object from `assets/config-template.json`.

Record both measurable `goals` and explicit `nonGoals`. Goals describe desired outcomes; they never imply permission. Non-goals make excluded actions reviewable during pilot and activation.

## Source entries

Each source contains:

- `id`: stable local identifier.
- `type`: connector or adapter kind, such as `github`, `linear`, `slack`, `email`, `zendesk`, `local-markdown`, or `custom`.
- `locator`: non-secret queue, project, channel, mailbox, label, or path selector.
- `secretKeys`: HQ secret key names only.
- `readPolicy`: eligible item and reply/event rules.
- `identityKey`: source-native immutable identity used for exact idempotency.
- `canonicalLocation`: issue, ticket, message, or thread coordinates used for evidence and handoff.

Keep source-native identifiers as evidence. Never deduplicate by title alone.

## Permission rules

`read` and `classify` may be enabled during the pilot. Every other permission is a separate boolean. `merge` and `deploy` must remain false because those actions belong to the repository's existing review and release workflows. `closeOrResolve` requires an explicit human terminal signal even after activation.

## Activation

Changing `mode` to `active` is necessary but insufficient. Enable only the minimum individual permission booleans approved after pilot review. Record the approval separately in the company project journal or another company-governed decision log.
