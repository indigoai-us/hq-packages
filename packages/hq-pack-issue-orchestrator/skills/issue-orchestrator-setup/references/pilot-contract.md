# Pilot contract

A valid pilot is observable and non-mutating.

1. Read at most `pilot.sampleSize` eligible items from the configured sources.
2. Preserve source IDs, timestamps, authorship class, and canonical links.
3. Apply exact identity dedupe, then propose any similarity grouping with evidence.
4. Classify each item, propose lifecycle state, scope match, owner, and next action.
5. Produce a handoff-shaped result for every item.
6. Record exclusions and the reason for each exclusion.
7. Write only the local pilot report path. Perform no source or repository writes.

The operator reviews false inclusions, false exclusions, unsafe proposals, unclear ownership, missing evidence, and permission requests. Activation requires an explicit decision after this review.
