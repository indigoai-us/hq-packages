# Routine: monthly performance review

**Invokes:** `/performance-review` — **MONTHLY** (non-interactive: zero questions).
**Cadence:** Monthly on the 2nd at 08:00; prior-month data has time to settle before it is compared.

## What it does

The review gathers the prior calendar month and the preceding month from every configured
read-only source. It identifies the current bottleneck, compares the last report's
recommendations with what was actually done, and ranks the next actions by evidence.
Partial coverage stays visible. This is the one scheduled routine allowed to append
evidence-qualified priors to `learnings.md`, preserving the product's single-writer
rule. With no data source, it names the needed key or export rather than treating an
absence as a result.

## The /schedule prompt

Run `/schedule` in your marketing workspace and paste:

```
Schedule: monthly, on the 2nd at 08:00 (my timezone).

Task: Run /performance-review in MONTHLY mode as defined by skills/performance-review/SKILL.md.
This is non-interactive: ask zero questions and use the mode defaults. Read the prior
calendar month and the month before from every configured read-only source, plus the
latest ./campaigns/performance/ report, assets.md, relevant learnings.md, brand.yaml,
and keyword-plan.md when present. Use GET or report-query endpoints only; do not alter
any connected service. Write ./campaigns/performance/<YYYY-MM>.md with coverage labels,
the bottleneck, month-over-month changes, acted-on versus unacted-on recommendations,
and three to five evidence-backed next actions mapped to skills. Append qualifying
priors to ./brand/learnings.md only when each has n= and source:, then update matched
ad-matrix.json results and assets.md statuses where the data supports it. Append one
report line to ./brand/assets.md. With no configured source, write a dated report naming
the exact key or export needed and stop. Reports, evidence-backed local priors, and local
bookkeeping only; never publish, send, deploy, spend, or change a third-party account.
```

## Every client (agency)

Same prompt with this first line instead: `For each client directory under ./brands/ that has a brand.yaml, set that client as active for the run and do the following, writing into that client's own folders; finish with one rollup line per client.`
Use `route.py --all-brands --goal convert` to enumerate the eligible clients.

## Local cron

```cron
0 8 2 * * cd /path/to/workspace && claude -p "Run /performance-review in MONTHLY mode using read-only sources, write the prior-month report, append only n=/source-qualified priors and matched local bookkeeping, add an assets row, and never publish or change a connected service." --allowedTools "Read,Write,WebFetch,WebSearch"
```

## Cloud caveat

A cloud routine runs in a fresh clone of your repo: it sees skills committed to that repo
(`.claude/skills/`), not plugin installs on your machine. For cloud runs, commit the
skills folder into the workspace repo first.
