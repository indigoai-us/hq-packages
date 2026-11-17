# Workflow: full-funnel build

Use this on-demand workflow when one offer needs a coordinated landing page, lead
magnet, welcome sequence, launch content, and paid-media briefs. It is orchestration
over existing skills, not a replacement for their judgment. Everything lands as a draft
under `./campaigns/<campaign-slug>/`; nothing is deployed, sent, pushed to an ESP, or
submitted to an ad platform.

## Workflow map

| Stage | Work | Completion rule |
|---|---|---|
| 0 | `/positioning-angles`, then `/lead-magnet` concept selection | The user approves an angle and one magnet concept. |
| 1 — parallel | `/direct-response-copy`, `/lead-magnet` BUILD, `/email-sequences` | Each branch writes its draft or records its gap. |
| 2 — parallel | `/landing-page` BUILD FROM COPY, `/content-atomizer`, `/paid-ads` CAMPAIGN BUILD | Each branch uses the actual Stage 1 assets, never placeholders. |
| 3 | Consolidation and QA gate | One honest campaign report plus a human go-live checklist. |

Stage 0 is the only decision point. Once the angle and concept are chosen, the parallel
branches use their documented defaults and ask no further questions. A failed branch is
captured as a gap in the report; it never stalls unrelated work.

## Prompt

Fill in the placeholders, then paste this into your marketing workspace:

```
Build a full funnel for: <offer in one sentence>. Campaign slug: <campaign-slug>.

You are the orchestrator. Read the active brand context before every branch and preserve
its constraints. All output belongs under ./campaigns/<campaign-slug>/ and is DRAFT for
human review. Never deploy, send, publish, schedule, upload, or spend.

STAGE 0 — work with me present. Run /positioning-angles for this offer and show the
recommended angle. After I approve one angle, run only the concept-selection phase of
/lead-magnet and let me choose one concept. Save the approved positioning and write
./campaigns/<campaign-slug>/ad-matrix.md and ad-matrix.json.

STAGE 1 — dispatch these three workstreams in parallel. Give each the approved angle,
approved magnet concept, relevant brand context, and its own SKILL.md.
1. /direct-response-copy: draft the landing-page copy with its score-and-rewrite loop,
   then leave the approved copy path and its handoff context for /landing-page.
2. /lead-magnet BUILD: create the selected lead magnet under the campaign directory.
3. /email-sequences: draft the welcome sequence from magnet to offer; report the
   deliverability preflight and never push it to an ESP.
Wait for all three. Record any failure and continue with the usable branches.

STAGE 2 — dispatch these three workstreams in parallel.
4. /landing-page BUILD FROM COPY: use the approved copy path, awareness level, and
   variants from Stage 1 to build the page under ./campaigns/<campaign-slug>/page/.
   Render and QA the page, but do not deploy it.
5. /content-atomizer: adapt the completed page copy and magnet for the platforms the brand
   actually operates; write drafts under ./campaigns/<campaign-slug>/social/.
6. /paid-ads CAMPAIGN BUILD: use the approved ad matrix and actual magnet hook to make
   campaign copy and creative briefs. Briefs only; do not launch anything.
Wait for all three.

STAGE 3 — QA gate and report. Check every produced file against its skill's stated
quality gate. Preserve reported scores exactly, label evidence as Data: LIVE, LOCAL
DOCS, or MODEL KNOWLEDGE, and flag missing or below-bar work as NEEDS HUMAN rather than
repairing it indefinitely. Write ./campaigns/<campaign-slug>/campaign-report.md with a
file inventory, scores and gaps, funnel map, human go-live checklist, and a measurement
follow-up for /performance-review. Mark the campaign planning in brand.yaml and append
an assets.md row only for deliverables not already registered. Finish with the summary
format in _system/output-format.md.
```

## Quality gate

The final report is the gate, not a claim that work is ready. It must show each branch's
actual score or the reason it has no score, retain research data labels, and list every
human action still required. Do not invent results, traffic, revenue, or launch status.

## Adjusting the workflow

You may remove a branch only when a real, approved equivalent asset already exists; give
its path to the remaining branches. Keep the stage order: atomization and ad work should
not start until they can use real campaign material.
