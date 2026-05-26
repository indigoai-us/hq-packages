---
name: migrate-nanoclaw
description: Upgrade a heavily-customized NanoClaw fork by extracting your customizations into a replayable migration guide, then reapplying them on a clean upstream checkout in a git worktree — no merge conflicts. HQ-adapted — operates on your cloned NanoClaw checkout (default repos/public/nanoclaw). Use for large divergence or heavy customization; for small routine updates use /update-nanoclaw.
---

# Migrate NanoClaw (HQ-adapted)

Intent-based upgrade. Instead of merging upstream into a divergent fork, extract the user's customizations into a markdown **migration guide** (intent + implementation detail), check out clean upstream in a git worktree, and reapply the customizations from the guide. This is the HQ-adapted version of NanoClaw's in-repo `migrate-nanoclaw` skill: it targets your **cloned checkout**.

## Step 0 — Resolve NANOCLAW_DIR (do this first)

```bash
NANOCLAW_DIR="${NANOCLAW_DIR:-repos/public/nanoclaw}"
```
If it does not exist or is not a git repo, **stop** and suggest `/setup-nanoclaw`. Every command below runs against this dir via `git -C "$NANOCLAW_DIR" …` or `cd "$NANOCLAW_DIR" && …`. Never run a bare git mutation from the HQ root.

> Worktree note: the Bash tool resets cwd between calls, so inside the worktree phase always use **absolute paths**. Capture them once: `PROJECT_ROOT="$(cd "$NANOCLAW_DIR" && pwd)"` and `WORKTREE="$PROJECT_ROOT/.upgrade-worktree"`.

## Phase 1 — Extract

### 1.0 Preflight
`git -C "$NANOCLAW_DIR" status --porcelain` — if dirty, offer stash/commit. Ensure `upstream` remote exists (default `https://github.com/nanocoai/nanoclaw.git`, confirm with user); `git -C "$NANOCLAW_DIR" fetch upstream --prune`. Detect `UPSTREAM_BRANCH` (`main`/`master`).

### 1.1 Assess scope
```bash
BASE=$(git -C "$NANOCLAW_DIR" merge-base HEAD "upstream/$UPSTREAM_BRANCH")
git -C "$NANOCLAW_DIR" log --oneline "$BASE..HEAD"
```
Check for an existing guide at `$NANOCLAW_DIR/.nanoclaw-migrations/guide.md` or `.nanoclaw-migrations/index.md`. Classify:
- **Tier 1** (lightweight divergence) → suggest `/update-nanoclaw` instead and stop.
- **Tier 2** (standard) → single `guide.md`.
- **Tier 3** (complex) → `.nanoclaw-migrations/` directory with `index.md` + section files + a migration plan.

### 1.2–1.4 Analyze customizations
Diff `$BASE..HEAD`. Identify applied skill-branch merges (`Merge branch 'skill/*'`), list `.claude/skills/`, and analyze customizations per area (config/build, `src/*.ts`, per-skill, container files). Use sub-agents for the exploration to keep token use low. Detect inter-customization conflicts.

### 1.5 Confirm with the user
Summarize what was found and confirm scope (use the runtime structured picker).

### 1.6 Migration plan (Tier 3 only)
Order of operations, staging, risk areas, interactions between customizations.

### 1.7 Write the migration guide
Write to `$NANOCLAW_DIR/.nanoclaw-migrations/guide.md` (Tier 2) or the `.nanoclaw-migrations/` dir (Tier 3). Capture, per customization: **intent** (why), **implementation** (what changed — verbatim snippets where the exact code matters), and the files touched. Header records `BASE` hash, current `HEAD`, and the upstream branch. Offer to commit the guide.

## Phase 2 — Upgrade

### 2.0 Preflight + new-changes guard
Re-check clean tree, read the guide, and compare the guide's recorded `HEAD` against the current `HEAD` — if they differ, the fork moved since the guide was written; refresh the guide first.

### 2.1 Safety net
```bash
HASH=$(git -C "$NANOCLAW_DIR" rev-parse --short HEAD); TS=$(date +%Y%m%d-%H%M%S)
git -C "$NANOCLAW_DIR" branch "backup/pre-migrate-$HASH-$TS"
git -C "$NANOCLAW_DIR" tag    "pre-migrate-$HASH-$TS"
```

### 2.2 Preview upstream
Review upstream `CHANGELOG.md` between `BASE` and `upstream/$UPSTREAM_BRANCH`; flag `[BREAKING]` entries.

### 2.3 Create the upgrade worktree
```bash
PROJECT_ROOT="$(cd "$NANOCLAW_DIR" && pwd)"; WORKTREE="$PROJECT_ROOT/.upgrade-worktree"
git -C "$NANOCLAW_DIR" worktree add "$WORKTREE" "upstream/$UPSTREAM_BRANCH" --detach
```

### 2.4 Reapply skill branches in the worktree
For each guide-listed applied skill branch:
```bash
git -C "$WORKTREE" merge "upstream/skill/<name>" --no-edit
```

### 2.5 Reapply customizations
Follow the guide, reapplying each customization onto the clean upstream tree in `$WORKTREE`. Because you're applying onto clean upstream, there are no merge conflicts — only the deliberate reapplication.

### 2.6 Validate (in the worktree)
```bash
cd "$WORKTREE" && pnpm install && pnpm run build && pnpm test
```

### 2.7 Live test (optional)
Stop the service (`launchctl unload ~/Library/LaunchAgents/com.nanoclaw.plist`), symlink the data dirs (`groups/ store/ data/ .env`) from `$PROJECT_ROOT` into `$WORKTREE`, `cd "$WORKTREE" && pnpm run dev`, then clean up the symlinks afterward.

### 2.8 Swap into the main checkout
Capture the worktree HEAD, back up `.nanoclaw-migrations` to `/tmp`, remove the worktree, fast-forward the checkout to the upgrade commit, restore the guide:
```bash
UPGRADE_COMMIT="$(git -C "$WORKTREE" rev-parse HEAD)"
cp -R "$PROJECT_ROOT/.nanoclaw-migrations" /tmp/nanoclaw-migrations-backup 2>/dev/null || true
git -C "$NANOCLAW_DIR" worktree remove --force "$WORKTREE"
git -C "$NANOCLAW_DIR" reset --hard "$UPGRADE_COMMIT"
cp -R /tmp/nanoclaw-migrations-backup "$PROJECT_ROOT/.nanoclaw-migrations" 2>/dev/null || true
```
Do **not** use `git checkout -B` here — `reset --hard` to the captured commit is the intended swap.

### 2.9 Post-upgrade
```bash
cd "$NANOCLAW_DIR" && pnpm install && pnpm run build
```
Restart the service (macOS `launchctl load ~/Library/LaunchAgents/com.nanoclaw.plist`; Linux `systemctl --user restart nanoclaw`). Summarize, give rollback instructions (`git -C "$NANOCLAW_DIR" reset --hard <backup-tag>`), and offer `git -C "$NANOCLAW_DIR" stash pop` if you stashed in 1.0.

## Principles

- Never proceed with a dirty tree; always create a rollback point.
- The guide is the source of truth, not raw diffs.
- Validate in a worktree before swapping into the main checkout.
- Data dirs (`groups/`, `store/`, `data/`, `.env`) are never touched by the migration.
- Use sub-agents for exploration; always use absolute paths inside the worktree.
- Operate only on `$NANOCLAW_DIR`; never the HQ root. Repo-local skills (`/add-<channel>`, `/update-skills`) run from inside the checkout's own session.
