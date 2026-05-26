---
name: update-nanoclaw
description: Bring upstream NanoClaw updates into a customized local install with preview, selective cherry-pick, and low token usage. HQ-adapted — operates on your cloned NanoClaw checkout (default repos/public/nanoclaw), not the current dir. Use when the user wants to update or sync NanoClaw, pull upstream changes, or catch up to the latest NanoClaw. For large divergence or heavy customization, use /migrate-nanoclaw instead.
---

# Update NanoClaw (HQ-adapted)

A low-token, git-native upstream sync for a customized NanoClaw install. This is the HQ-adapted version of NanoClaw's in-repo `update-nanoclaw` skill: it targets your **cloned checkout** so it is safe to invoke from an HQ session.

## Step 0 — Resolve NANOCLAW_DIR (do this first)

```bash
NANOCLAW_DIR="${NANOCLAW_DIR:-repos/public/nanoclaw}"
```

- If `$NANOCLAW_DIR` does not exist or is not a git repo, **stop** and suggest `/setup-nanoclaw`.
- **Every** git / pnpm / build / service command below runs against this dir — use `git -C "$NANOCLAW_DIR" …` or `cd "$NANOCLAW_DIR" && …` in a single Bash call. Never run a bare git mutation from the HQ root (it's blocked, and it would target the wrong repo).

## Step 1 — Preflight

```bash
git -C "$NANOCLAW_DIR" status --porcelain
```
If dirty, stop and offer to stash or commit before continuing. Then ensure the upstream remote exists:

```bash
git -C "$NANOCLAW_DIR" remote -v
```
If no `upstream`, add it (default URL, confirm with the user):
```bash
git -C "$NANOCLAW_DIR" remote add upstream https://github.com/nanocoai/nanoclaw.git
```
Detect the upstream default branch (`main` or `master`) → `UPSTREAM_BRANCH`, then:
```bash
git -C "$NANOCLAW_DIR" fetch upstream --prune
```

## Step 2 — Safety net

Create a rollback point before touching anything:
```bash
HASH=$(git -C "$NANOCLAW_DIR" rev-parse --short HEAD); TS=$(date +%Y%m%d-%H%M%S)
git -C "$NANOCLAW_DIR" branch "backup/pre-update-$HASH-$TS"
git -C "$NANOCLAW_DIR" tag    "pre-update-$HASH-$TS"
```

## Step 3 — Preview

```bash
BASE=$(git -C "$NANOCLAW_DIR" merge-base HEAD "upstream/$UPSTREAM_BRANCH")
git -C "$NANOCLAW_DIR" log --oneline "$BASE..upstream/$UPSTREAM_BRANCH"
git -C "$NANOCLAW_DIR" diff --name-only "$BASE..upstream/$UPSTREAM_BRANCH"
```
Bucket changed files for the summary: **Skills** (`.claude/skills/`), **Host** (`src/`), **Container** (`container/`), **Build/config** (`package.json`, `pnpm-lock.yaml`, `tsconfig*.json`), **Other**. If divergence is large, suggest `/migrate-nanoclaw` instead.

Then ask the user (use the runtime structured picker, one question) which path to take:
- **A — Full update** (merge upstream; default)
- **B — Selective** (cherry-pick specific commits)
- **C — Abort**
- **D — Rebase**

## Step 4 — Apply

**Conflict preview first** (non-destructive):
```bash
git -C "$NANOCLAW_DIR" merge --no-commit --no-ff "upstream/$UPSTREAM_BRANCH"
git -C "$NANOCLAW_DIR" diff --name-only --diff-filter=U
git -C "$NANOCLAW_DIR" merge --abort
```

- **4A Merge** — `git -C "$NANOCLAW_DIR" merge --no-edit "upstream/$UPSTREAM_BRANCH"`.
- **4B Cherry-pick** — `git -C "$NANOCLAW_DIR" cherry-pick <sha>…` for the chosen commits.
- **4D Rebase** — `git -C "$NANOCLAW_DIR" rebase "upstream/$UPSTREAM_BRANCH"`.

Resolve conflicts by editing only the conflict regions; preserve the user's customizations. Never discard their changes wholesale.

## Step 4.5 — Install deps (if lockfiles changed)

```bash
cd "$NANOCLAW_DIR" && pnpm install
# container runtime deps (only if container/ changed and bun is present):
cd "$NANOCLAW_DIR/container/agent-runner" && bun install
```

## Step 5 — Validate

```bash
cd "$NANOCLAW_DIR" && pnpm run build && pnpm test
# if container/ changed:
cd "$NANOCLAW_DIR" && pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit && ./container/build.sh
```
Treat failures as blockers — fix or roll back (Step 7), do not ship a broken sync.

## Step 6 — Breaking changes

Diff the changelog and surface any breaking notes:
```bash
git -C "$NANOCLAW_DIR" diff "$BASE..upstream/$UPSTREAM_BRANCH" -- CHANGELOG.md
```
NanoClaw flags breaking changes as lines like `` [BREAKING] <desc>. Run `/<skill-name>` to <action>. `` Those referenced skills are **repo-local** (they live in the NanoClaw checkout, not in HQ). Surface them to the user and tell them to run those skills from a Claude session opened inside `$NANOCLAW_DIR`.

## Step 7 — Skill / channel / provider follow-ups

- Upstream may ship new `upstream/skill/*` branches — note them; the user runs `/update-skills` **inside `$NANOCLAW_DIR`**.
- Detect installed channels/providers from `src/channels/index.ts` and `src/providers/index.ts`; re-running `/add-<name>` (also repo-local) happens **inside `$NANOCLAW_DIR`**.

## Step 8 — Summary + restart

Report: backup tag, old HEAD, new HEAD. Restart the NanoClaw service so the new code is live (run in a terminal):
- macOS: `launchctl kickstart -k gui/$(id -u)/com.nanoclaw`
- Linux: `systemctl --user restart nanoclaw`
- Dev: `cd "$NANOCLAW_DIR" && pnpm run dev`

**Rollback** if needed: `git -C "$NANOCLAW_DIR" reset --hard <backup-tag>`.

## Principles

- Never proceed with a dirty tree; always create a backup branch + tag first.
- Operate only on `$NANOCLAW_DIR`; never the HQ root.
- Data dirs (`groups/`, `store/`, `data/`, `.env`) are never modified by this skill.
- Repo-local skills run inside the NanoClaw checkout, not HQ.
