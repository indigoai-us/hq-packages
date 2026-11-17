# Workflow: campaign fan-out

Use this on-demand workflow after a source asset is finished and you need native drafts
for several active platforms. It creates one dedicated treatment per platform plus
creative briefs, then runs a bounded QA gate before you review anything. It is wider
than a normal `/content-atomizer` request, so choose only platforms the brand actually
uses. Everything is a draft; this workflow never posts, schedules, generates media, or
uploads files.

## Workflow map

| Stage | Work | Output |
|---|---|---|
| 0 | Shared source and evidence brief | One common brief for all workstreams |
| 1 — parallel | One `/content-atomizer` workstream per platform, plus creative briefs | Native treatments and one briefs file |
| 2 | QA gate | Scores, one targeted redo at most, then NEEDS HUMAN |
| 3 | Consolidation | Fan-out report and registered campaign assets |

## Prompt

Fill in the placeholders, then paste this into your marketing workspace:

```
Fan out this completed source asset: <path or URL>. Platforms: <only real active
platforms>. Campaign slug: <campaign-slug>.

You are the orchestrator. All output belongs under ./campaigns/<campaign-slug>/social/
and is DRAFT for human review. Do not publish, schedule, upload, generate media, or make
changes to an external platform.

STAGE 0 — create the shared brief. Read the source in full, voice-profile.md,
positioning.md when present, and relevant evidence-backed entries in learnings.md. Check
the current platform facts in algo-cache.md or the content-atomizer references and note
any stale source. Extract the core idea, supported claims, specific proof, usable hooks,
and the data labels every workstream must retain. Do not turn unpublished local intent
into a claimed public fact.

STAGE 1 — run in parallel. Dispatch one /content-atomizer workstream for each named
platform. Each receives the shared brief, brand voice adaptations, and current platform
facts, then writes a native treatment to
./campaigns/<campaign-slug>/social/<platform>/<YYYY-MM-DD>-fanout.md. Dispatch one
creative-brief workstream in parallel: it writes
./campaigns/<campaign-slug>/social/creative-briefs.md with production-ready visual
briefs for the treatments that need them. A failed platform is a documented gap, not a
reason to stop the other workstreams.

STAGE 2 — QA gate. Score every treatment from 0 to 100 for native-format fit, hook,
voice fidelity, preserved substance, and slop avoidance. The threshold is 70. Return a
below-threshold file to its own workstream once with the weak dimensions named; rescore.
If it remains below 70, label it NEEDS HUMAN with score history. Never retry more than
once and never quietly substitute generic copy.

STAGE 3 — consolidate. Write
./campaigns/<campaign-slug>/social/fanout-report.md with the platform-by-format-by-score
matrix, NEEDS HUMAN items and reasons, creative-brief index, manual publish sequencing,
and priors applied. Preserve Data: LIVE, LOCAL DOCS, and MODEL KNOWLEDGE labels. Append
one assets.md row for each unregistered file, then provide the summary format in
_system/output-format.md. Do not claim publication or results that have not occurred.
```

## Quality gate

The score is a review aid, not proof that a draft will perform. The gate protects
platform specificity and factual substance while making weak outputs visible. It stops
after one targeted redo so a human, rather than an endless loop, decides what happens
next.

## Adjusting the workflow

Start with three or four platforms if the source is complex. When the briefs are approved,
hand them to `/creative` in a separate, reviewable run; keeping media generation outside
this workflow preserves a clear human approval point.
