# hq-pack-engineering

Engineering capabilities for HQ — code review, debugging, testing, PR lifecycle, story execution (Ralph), and the worker team that executes coding work.

Install when you use HQ to manage repos. Vanilla `hq-core` is an orchestration layer; this pack adds the slash commands and workers most coding workflows assume.

## Install

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-engineering
```

`scan-packages.sh` wires the pack into well-known locations on the next session start (or run it manually after install):

- Skills → `.claude/skills/{name}/`
- Workers → `core/workers/public/{name}/`
- Knowledge → `core/knowledge/public/{name}/`
- Policies → `core/policies/{name}.md`

All under bare names — `/tdd`, `/review`, `/architect`, etc. work unchanged after install.

## What you get

### Skills (23)

| Skill | Purpose |
|---|---|
| `architect` | Surface architectural friction, deepening opportunities; deletion-test scoring |
| `clean-worktree` | Merge a detached worktree branch back into local main; remove worktree and branch |
| `codebase-design` | Shared deep-module vocabulary (module/interface/depth/seam) + design-it-twice reference |
| `commit-main` | Commit every dirty file in current repo when on `main` |
| `deep-plan` | Research subagents + 3-tier 15-question interview for large or strategic PRDs |
| `diagnose` | Disciplined diagnosis loop for hard / non-deterministic / performance bugs |
| `discover` | Pull a repo into HQ at latest main; parallel exploration; synthesize knowledge |
| `document-release` | Post-ship documentation sync — README, CLAUDE.md, architecture docs, INDEX files |
| `domain-modeling` | Build and sharpen a project's domain glossary in `CONTEXT.md`; hand ADRs to `/adr` |
| `execute-task` | Execute a single PRD story through coordinated worker phases (Ralph pattern) |
| `investigate` | Iron Law debugging — root cause investigation before any fixes, scope lock |
| `land` | Land a PR — monitor CI, resolve review issues, merge, monitor production |
| `land-batch` | Triage, review, sequentially merge multiple open PRs |
| `outpost-host` | Host a static or full-stack app on the HQ Outpost / EC2 VM via nginx — Outpost/EC2 only |
| `prd` | Create an execution-ready PRD (`prd.json` + README) with full HQ context |
| `quality-gate` | Universal pre-commit quality checks (typecheck, lint, test, coverage) with `--fix` |
| `review` | Paranoid pre-landing code review — four-severity analysis with file:line refs |
| `run-pipeline` | Multi-project pipeline orchestrator — triage, execute, PR, review, deploy |
| `run-project` | Run a project — default inline execution; `--ralph-mode` for background orchestrator |
| `ship` | Meta pipeline: review → land → deploy → smoke → heal → monitor until KPIs are healthy |
| `tdd` | Enforce test-driven development with RED→GREEN→REFACTOR cycle |
| `to-tickets` | Break a plan/spec into tracer-bullet vertical-slice tickets with blocking edges |
| `wayfinder` | Chart a shared map of investigation tickets for work too big for one agent session |

### Workers (6)

| Worker | Purpose |
|---|---|
| `accessibility-auditor` | WCAG 2.2 AA auditing (keyboard nav, screen reader, zoom, reduced motion, contrast) |
| `frontend-designer` | Bold UI generation using Anthropic skill; design-styles context |
| `performance-benchmarker` | Core Web Vitals, load testing, k6, Lighthouse, stress/endurance |
| `qa-tester` | Adversarial website testing — defaults to FAIL, requires screenshot evidence |
| `security-scanner` | Security scanning and vulnerability detection; PII/credentials pre-deploy |
| `site-builder` | Build and deploy local business websites from template + config |

### Knowledge

| Slug | Purpose |
|---|---|
| `Ralph` | Execute-task / run-project orchestration knowledge (deterministic worker-phase pattern) |
| `ai-security-framework` | Security-scanner reference framework |
| `dev-team` | Patterns, troubleshooting, workflows for dev team |

### Policies

| Slug | Enforcement | Summary |
|---|---|---|
| `e2e-testing-standards` | hard | E2E verification standards; back-pressure signal for stories |
| `hq-bugfix-requires-tests` | hard | Every bugfix ships a regression test |
| `hq-no-test-shortcuts` | hard | No `test.skip`, false positives, or loosened assertions |

## Why an opt-in pack

Vanilla `hq-core` is intentionally minimal — orchestration layer over Claude Code, Cursor, and Codex. The engineering surface assumes a coding workflow: a repo, a PR pipeline, tests, deploys. Many HQ users (founders, ops, sales, knowledge-work tenants) never touch that surface and benefit from a smaller default.

Engineering teams `hq install` this pack once per HQ instance and get the full developer experience back in bare-name form.

## Dependencies between skills (after install)

- `execute-task` → `run-project`, `quality-gate`, `learn` (in core), `document-release`
- `run-project` → `execute-task`, `land`, `quality-gate`
- `run-pipeline` → `run-project`, `land`
- `land` → GitHub CLI, no other pack-skill deps
- `prd`, `deep-plan` → feed `run-project`; `deep-plan` also triggers `review-plan` (in core)
- `review` / `investigate` / `diagnose` → independent; feed `architect` and bug-creation flows
- `tdd`, `quality-gate` → independent pre-commit gates
- `architect` → `codebase-design` (deep-module vocabulary), `domain-modeling` (glossary), `/adr` (in core)
- `codebase-design`, `domain-modeling` → reference skills; feed `architect`, `tdd`, `diagnose`
- `wayfinder` → feeds `prd` / `deep-plan`; uses `deep-research`, `brainstorm`, `domain-modeling`
- `to-tickets` → feeds `execute-task` / `run-project`; complements `prd`

All bare names — cross-references stay working as long as both ends are installed (or both stay in core).

## Versioning

`v1.0.0` — initial extraction from `hq-core` v14.2.x. Tracks `hq-core` major versions for breaking-change alignment.

`v1.4.0` — added `codebase-design`, `domain-modeling`, `to-tickets`, and `wayfinder`, ported and genericized from [`mattpocock/skills`](https://github.com/mattpocock/skills) (upstream commit `391a270`); refreshed `diagnose` (Phase-1 red-loop gate + minimise step), `tdd` (seams, tautological/horizontal-slicing anti-patterns), and `architect` (design-it-twice, recommendation badges) with upstream improvements.

## License

MIT. See repository root.
