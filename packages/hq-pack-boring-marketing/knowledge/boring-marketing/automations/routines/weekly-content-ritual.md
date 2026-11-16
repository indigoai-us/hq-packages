# Routine: weekly content ritual

**Invokes:** `/newsletter` — **Edition**, plus `/social-content` — **CADENCE** (non-interactive: zero questions).
**Cadence:** Every Friday at 06:00; drafts are ready for a human review before the next publishing window.

## What it does

This routine converts the week's real work into a newsletter draft and a native social
plan. It derives material from the asset registry, recent learnings, and new campaign
files instead of asking a scheduled run to invent a topic. Every deliverable begins
`DRAFT — human review required`. A missing format or social canon creates a setup-needed
stub for that half while the other half can still complete.

## The /schedule prompt

Run `/schedule` in your marketing workspace and paste:

```
Schedule: every Friday at 06:00 (my timezone).

Task: This is a non-interactive content run: ask zero questions and mark every output
“DRAFT — human review required” on its first line. Read ./brand/assets.md from the last
seven days, relevant learnings.md, new files under ./campaigns/, voice-profile.md, and
the newsletter format and social canon when they exist. Run /newsletter in Edition mode:
write ./campaigns/newsletters/<YYYY-MM-DD>-<topic-slug>.md from the strongest verified
material, or write <YYYY-MM-DD>-SETUP-NEEDED.md if the format is absent. Run
/social-content in CADENCE mode: write ./campaigns/social/<YYYY>-W<ww>.md with three to
five distinct, evidence-backed drafts, or a matching SETUP-NEEDED report if the canon is
absent. Do not pad weak material. Append one line to ./brand/assets.md for each file.
Never write learnings.md: draft possible entries in the relevant report. Drafts and
reports only; never send, schedule, post, upload, deploy, or publish anything.
```

## Every client (agency)

Same prompt with this first line instead: `For each client directory under ./brands/ that has a brand.yaml, set that client as active for the run and do the following, writing into that client's own folders; finish with one rollup line per client.`
Use `route.py --all-brands --goal authority` to enumerate the eligible clients.

## Local cron

```cron
0 6 * * 5 cd /path/to/workspace && claude -p "Run the non-interactive newsletter Edition and social-content CADENCE ritual from this week's real assets; write human-review drafts or setup-needed stubs, append each asset row, draft proposed learnings only, and never publish." --allowedTools "Read,Write,WebFetch,WebSearch"
```

## Cloud caveat

A cloud routine runs in a fresh clone of your repo: it sees skills committed to that repo
(`.claude/skills/`), not plugin installs on your machine. For cloud runs, commit the
skills folder into the workspace repo first.
