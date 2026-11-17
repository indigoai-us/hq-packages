# Routine: weekly competitor watch

**Invokes:** `/competitive-intel` — **WATCH** (non-interactive: zero questions).
**Cadence:** Every Monday at 07:00; a start-of-week delta gives the team time to act on a meaningful change.

## What it does

This routine reuses the roster and Watch baseline in `competitors.md` rather than
guessing who matters. It rechecks each recorded public surface, then produces a
deltas-only report with evidence links and data labels. No movement is a valid short
result. A missing baseline produces a dated setup report instead of an invented roster.

## The /schedule prompt

Run `/schedule` in your marketing workspace and paste:

```
Schedule: every Monday at 07:00 (my timezone).

Task: Run /competitive-intel in WATCH mode as defined by skills/competitive-intel/SKILL.md.
This is non-interactive: ask zero questions and use the mode defaults. Read the active
brand's competitors.md Watch baseline and positioning.md when present. Recheck the
recorded competitors' homepage, offer, pricing, public content, and visible campaign
surfaces; label observed evidence Data: LIVE and state any unreachable surface.
Write ./campaigns/competitor-watch/<YYYY-MM-DD>.md with only meaningful deltas, their
evidence, why each matters, no-movement coverage, and at most three proposed reactions.
Version the prior competitors.md in .history before refreshing its Watch baseline, then
bump brand.yaml. Append one line to ./brand/assets.md. If no usable baseline exists,
write a short dated report explaining that an interactive teardown is needed and stop.
Never write learnings.md: put possible entries under “Proposed learnings” in the report.
Reports only; never publish, contact, post, send, deploy, or change a third-party account.
```

## Every client (agency)

Same prompt with this first line instead: `For each client directory under ./brands/ that has a brand.yaml, set that client as active for the run and do the following, writing into that client's own folders; finish with one rollup line per client.`
Use `route.py --all-brands --goal authority` to enumerate the eligible clients.

## Local cron

```cron
0 7 * * 1 cd /path/to/workspace && claude -p "Run /competitive-intel in WATCH mode. Read the active brand Watch baseline, write the dated competitor delta report, refresh the versioned local baseline, append assets, draft proposed learnings only, and never publish." --allowedTools "Read,Write,WebFetch,WebSearch"
```

## Cloud caveat

A cloud routine runs in a fresh clone of your repo: it sees skills committed to that repo
(`.claude/skills/`), not plugin installs on your machine. For cloud runs, commit the
skills folder into the workspace repo first.
