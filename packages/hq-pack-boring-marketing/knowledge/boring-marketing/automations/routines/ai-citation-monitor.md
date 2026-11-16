# Routine: AI citation monitor

**Invokes:** `/ai-search` — **MONITOR** (non-interactive: zero questions).
**Cadence:** Every other Tuesday at 07:00; this creates a consistent comparison interval without reacting to one noisy capture.

## What it does

The monitor replays the exact money-query baseline from the latest audit or monitor
report. It identifies citations gained, lost, and held per query, plus newly cited
domains, while stating capture gaps plainly. The query set never changes in a scheduled
run. Without a baseline, it writes an audit-needed report and stops.

## The /schedule prompt

Run `/schedule` in your marketing workspace and paste:

```
Schedule: every two weeks, Tuesday at 07:00 (my timezone).

Task: Run /ai-search in MONITOR mode as defined by skills/ai-search/SKILL.md. This is
non-interactive: ask zero questions. Read the newest ./campaigns/ai-search/audit-*.md
or monitor-*.md Monitor baseline and rerun the same money queries verbatim; never invent
or expand the query set. Diff citations per query and entity, recording GAINED, LOST,
HELD, newly cited domains, coverage gaps, and evidence with Data: LIVE labels. Write
./campaigns/ai-search/monitor-<YYYY-MM-DD>.md with the findings, up to three proposed
reactions, and a refreshed Monitor baseline for the next run. Append one line to
./brand/assets.md. If no baseline exists, write a short dated report saying that
/ai-search AUDIT must run first, then stop. Never write learnings.md: draft only
traceable-cause candidates under “Proposed learnings” in the report. Reports only;
never publish, post, send, deploy, or change a third-party account.
```

## Every client (agency)

Same prompt with this first line instead: `For each client directory under ./brands/ that has a brand.yaml, set that client as active for the run and do the following, writing into that client's own folders; finish with one rollup line per client.`
Use `route.py --all-brands --goal authority` to enumerate the eligible clients.

## Local cron

```cron
0 7 * * 2 cd /path/to/workspace && [ $(( $(date +\%V) % 2 )) -eq 0 ] && claude -p "Run /ai-search in MONITOR mode using the existing money-query baseline verbatim; write the dated monitor report and refreshed baseline, append assets, draft proposed learnings only, and never publish." --allowedTools "Read,Write,WebFetch,WebSearch"
```

## Cloud caveat

A cloud routine runs in a fresh clone of your repo: it sees skills committed to that repo
(`.claude/skills/`), not plugin installs on your machine. For cloud runs, commit the
skills folder into the workspace repo first.
