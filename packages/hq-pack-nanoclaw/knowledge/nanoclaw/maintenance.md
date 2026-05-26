# NanoClaw — Maintenance Methodology

NanoClaw is meant to be forked and customized, which makes "stay current with upstream" a real problem. There are two complementary strategies, exposed as the `/update-nanoclaw` and `/migrate-nanoclaw` skills (HQ-adapted in this pack to operate on your cloned checkout).

## Two strategies

### `/update-nanoclaw` — low-token merge sync (default for routine updates)

A git-native upstream sync: preview the diff bucketed by area (skills / host / container / build), create a backup branch + tag, then merge (or cherry-pick, or rebase) upstream into your fork, resolving only the conflict regions while preserving your customizations. Validates with `pnpm run build` + `pnpm test`, parses `[BREAKING]` changelog lines, and points at any repo-local follow-up skills.

Use it when divergence is modest and conflicts are tractable.

### `/migrate-nanoclaw` — intent-based replay (for heavy forks)

When a fork has diverged a lot, merging produces painful conflicts. Migration sidesteps them: it **extracts** your customizations into a markdown migration guide (intent + the exact code that matters), checks out **clean upstream** in a git worktree, and **replays** your customizations onto it from the guide. Because you apply onto clean upstream, there are no merge conflicts — only deliberate reapplication. It validates in the worktree, then swaps the validated tree into your checkout with a captured-commit `reset --hard`.

Use it for Tier 3 divergence, or when a merge would touch many overlapping files.

## Shared safety rules

- Never proceed with a dirty tree.
- Always create a rollback point (backup branch + tag) before changing anything.
- Validate (`build` + `test`) before declaring success; for container changes, also typecheck + rebuild the image.
- Data directories — `groups/`, `store/`, `data/`, `.env` — are never modified by either workflow.
- The migration guide (not raw diffs) is the source of truth for what your fork intends.

## HQ adaptation notes

The in-repo originals assume the current working dir is the NanoClaw fork and they phone home to a telemetry endpoint. The HQ-adapted versions in this pack:

- resolve a `NANOCLAW_DIR` (default `repos/public/nanoclaw`) and run every command against that checkout via `git -C` / `cd`, so they are safe to invoke from an HQ session;
- run repo-local follow-up skills (`/update-skills`, `/add-<channel>`) from inside the NanoClaw checkout's own Claude session, not from HQ;
- ship **no** telemetry.

## When neither fits

If you find yourself fighting both — e.g. you want upstream but your fork's intent has drifted so far that the guide is mostly rewrites — it's a signal to reconsider what you've forked vs. what should be a clean extension. NanoClaw's channels/providers-as-skills model exists precisely so most customization rides on top of trunk rather than diverging it.
