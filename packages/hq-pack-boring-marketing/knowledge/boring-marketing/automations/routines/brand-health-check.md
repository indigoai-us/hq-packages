# Routine: brand health check

**Invokes:** local brand-memory checks plus `_system/scripts/refresh_check.py` (non-interactive: zero questions).
**Cadence:** Monthly on the 1st at 08:00; it exposes stale inputs before the performance review reads them.

## What it does

The health check audits local brand memory without changing the files it examines. It
checks manifest integrity, profile age, TTL headers, missing asset paths, and quiet
campaigns. Its report sorts attention by blast radius and points to the skill that can
refresh each stale input. A healthy brand gets a brief report instead of padded output.

## The /schedule prompt

Run `/schedule` in your marketing workspace and paste:

```
Schedule: monthly, on the 1st at 08:00 (my timezone).

Task: Run a local, non-interactive brand-health check: ask zero questions. Resolve the
active brand directory, otherwise use ./brand/. Read brand.yaml, listed profile files,
their updated dates and mtimes, assets.md, learnings.md, and active campaign entries.
Check manifest drift and classify profile files as FRESH, AGING, STALE, or UNVERIFIED.
Resolve <skills-pack-path> as the directory containing _system/scripts/refresh_check.py.
For each existing path, run: python3 <skills-pack-path>/_system/scripts/refresh_check.py
./brand/algo-cache.md <skills-pack-path>/skills/creative/references/MODEL_REGISTRY.md
<skills-pack-path>/skills/*/references/*-facts.md. Skip missing paths, report a missing
or unparseable header as UNVERIFIED, and copy the freshness output into the report
without performing a refresh. Write ./campaigns/brand-health/<YYYY-MM-DD>.md with the
status table, freshness output, housekeeping signals, and one to five suggested refreshes
ordered by blast radius. Append one line to ./brand/assets.md. If no brand memory exists,
write a dated report saying /start-here must run first and stop. Never write learnings.md
or modify audited files: draft any proposed entry inside the report. Reports only; never
publish, send, deploy, spend, or change a third-party account.
```

## Every client (agency)

Same prompt with this first line instead: `For each client directory under ./brands/ that has a brand.yaml, set that client as active for the run and do the following, writing into that client's own folders; finish with one rollup line per client.`
Use `route.py --all-brands --goal unsure` to enumerate the eligible clients.

## Local cron

```cron
0 8 1 * * cd /path/to/workspace && claude -p "Run local brand-memory checks and refresh_check.py on existing cache and fact paths, write the dated freshness report and an assets row, do not refresh or alter audited files, draft proposed learnings only, and never publish." --allowedTools "Read,Write,WebFetch,WebSearch"
```

## Cloud caveat

A cloud routine runs in a fresh clone of your repo: it sees skills committed to that repo
(`.claude/skills/`), not plugin installs on your machine. For cloud runs, commit the
skills folder into the workspace repo first.
