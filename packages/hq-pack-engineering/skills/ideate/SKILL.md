---
name: ideate
description: Run the whole idea → brainstorm → PRD pipeline in one session as a gated background workflow — capture the idea, research and compare approaches, pause only at real human decisions (premise, approach, open questions), and end with an execution-ready prd.json. Use when the user says "/ideate", "take this idea to a PRD", "run the planning pipeline", or wants idea/brainstorm/plan chained without invoking each step by hand.
allowed-tools: Read, Write, Grep, Glob, Bash, Bash(node:*), Bash(bash:*), Bash(ls:*), Bash(cat:*), Bash(jq:*), Bash(tail:*), AskUserQuestion, Task
argument-hint: "[company] <idea description> [--board <id>]"
---

# Ideate — One-Command Idea → Brainstorm → PRD

Chains the planning pipeline (`/idea` capture → `/brainstorm` → PRD) in a
single session. The heavy stages run as background Codex agents via the
bundled workflow runner; the run **pauses at human gates** (weak premise,
approach selection, open PRD questions) and resumes in place the moment you
answer. Decisions are durable — a crashed run re-launched never re-asks.

Protocol: `core/knowledge/public/hq-core/workflow-gates-spec.md` (requires an
hq-core with `core/scripts/workflow-gate.sh`; see Fallback below when absent).

**Important:** planning only. This skill ends at an execution-ready
`prd.json`. Execution stays a fresh-session `/run-project` — same hard stop as
the PRD skill.

## Step 1: Parse & Resolve

- First word matches a company slug in `companies/manifest.yaml` → anchor
  `{co}`, announce ("Anchored on **{co}**"). Otherwise resolve from cwd, else
  ask (one AskUserQuestion).
- `--board <id>` → expanding an existing board idea.
- Remaining text = the idea description. If empty, ask for it (fold into the
  same single question as company when both are missing).

## Step 2: One-Batch Interview (interview-first)

One AskUserQuestion batch for the predictable unknowns — skip anything already
clear from the description:

1. **Direction** — A. Speed to ship · B. Quality/durability · C. Exploration
   (prove/disprove first) · D. Cost minimization
2. **Hard constraints?** — free text (timeline, must-use tech, budget), or none

Everything discovered later arrives as gates, not questions asked upfront.

## Step 3: Preflight

Run these cheap checks; on any failure use the Fallback (Step 7):

```bash
command -v node && command -v codex
test -f core/scripts/workflow-gate.sh
```

Also resolve `{skill_dir}` = this skill's directory (contains `scripts/`).

## Step 4: Launch the Gated Pipeline (background)

Launch the bundled runner on the bundled pipeline script as a background
task (do NOT wait in the foreground):

```bash
node {skill_dir}/scripts/codex-workflow.mjs {skill_dir}/scripts/ideate-pipeline.mjs \
  --args '{"company":"{co}","description":"{description}","direction":"{direction}","constraints":"{constraints}","boardId":"{board id or omit}"}' \
  --run-dir workspace/tmp/codex-workflow/ideate-{co}-{ts}
```

The run writes `GATE OPEN` lines to stdout when it needs a human, and gate
files to `workspace/gates/pending/`.

## Step 5: Watch → Relay Gates → Answer

Loop until the background task exits:

1. Wait on either the task's completion or a pending gate
   (`bash core/scripts/workflow-gate.sh wait-pending --timeout 60` in a
   background/monitor slot, or watch the task's stdout for `GATE OPEN`).
2. On a gate: read its JSON from `workspace/gates/pending/{id}.json` and ask
   the user with **one AskUserQuestion per gate** — options from the gate file,
   recommended option first and marked "(Recommended)", plus the gate's own
   defer/park option if present. Free-text answers ride `--notes`.
3. Answer: `bash core/scripts/workflow-gate.sh answer {id} "{choice}"
   [--notes "..."]`. The paused run resumes on its own — do not relaunch it.
4. Between gates, stay quiet. Surface at most one milestone beat per phase
   (the runner's phase lines: Capture / Brainstorm / Decide / PRD / Resolve).
5. If a `TIMEOUT WARNING` repeats for the same agent with no log growth,
   inspect its log (path is in the warning) before deciding to kill the
   process group listed in the warning — never pattern-kill.

Do not run other heavy work in this session while the pipeline is mid-flight;
answering gates promptly is the job.

## Step 6: Verify & Close

When the task exits, parse its final JSON:

- `status: "parked"` → premise was weak and the user parked it. Confirm the
  board shows the idea as `exploring` with a `brainstorm_path`, report that
  outcome plainly, done.
- `status: "prd_ready"` → **independently verify** (never trust agent
  self-report): the PRD file exists and parses, story count > 0, board entry
  status is `prd_created`, brainstorm frontmatter says `promoted`. If
  verification fails, read the run journal
  (`{run-dir}/journal.jsonl`) and the failing agent's log, fix forward or
  report the precise failure.
- Print the close-out (pack-aware, mirroring the PRD skill):

```
Project **{name}** is PRD-ready — {storiesTotal} stories
({investigationStories} pre-flight investigations from deferred decisions).
Files: {prdPath} (+ README.md)
Decisions locked during the run: {decisionsApplied}

To execute, start a fresh session and run:
  /run-project {name}
```

- Write the same lightweight auto-checkpoint thread file the PRD skill writes
  on completion (type `auto-checkpoint`, trigger `ideate-complete`), so a
  fresh session can pick up execution.
- Leave `workspace/gates/answered/` entries in place — they are the re-run
  memory. Do not clear them while the project is live.

## Step 7: Fallback — Guided Mode (no codex / node / gate CLI)

Run the same pipeline sequentially **in this session**: execute
`.claude/skills/idea/SKILL.md`, then `.claude/skills/brainstorm/SKILL.md`,
then the PRD skill, asking their decision points directly via AskUserQuestion
as those skills already specify. Same outputs, no background run. Announce
which mode is in use in one line at launch time.

## Rules

- **Gates are the only mid-run questions.** Never poll the user in chat while
  the run is alive; relay gates through AskUserQuestion, one at a time.
- **Answer files are capabilities for the run** — write them only via
  `core/scripts/workflow-gate.sh` so validation applies.
- **No implementation.** PRD-ready is the finish line; `/run-project` in a
  fresh session executes.
- **Company isolation** — the pipeline runs anchored on one company; all
  stage agents read/write only that company's scope.
- **Verify independently** — file existence, JSON parse, story count, board
  status. Agent-reported success is a claim, not a fact.
- **One pipeline per session.** If gates from an unrelated run are pending at
  launch (`workflow-gate.sh list`), surface them first — a paused run resumes
  the moment they're answered.

## See also

- `/idea`, `/brainstorm` — the core planning stages this pipeline chains
- `/prd`, `/deep-plan` — PRD generation (this pipeline uses the PRD skill)
- `/run-project` — execute the resulting PRD (fresh session)
- `core/knowledge/public/hq-core/workflow-gates-spec.md` — the gate protocol
