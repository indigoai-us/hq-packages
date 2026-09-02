# 06 — Sheets

A **sheet** is a full-page report: title, lede, KPIs, several charts, notes, and a
source rail, composed as one file. Sheets live in `assets/sheets/`.

## When a sheet is the deliverable

Only when the user explicitly asks for a report, one-pager, brief, monthly or
weekly report, annual review, poster, or dashboard page. "Analyse this" is not a
request for a sheet; deliver the strongest one to three charts and offer the
sheet in a sentence. Rich data is not a reason to switch modes either.

## Roster

| Id | Name | Width | Charts | Reads in | Built for |
|---|---|---|---|---|---|
| `sheet.one-pager` | Survey one-pager | 1080 flowing | 3 + KPI row | 2 min | a survey, a study, a launch readout |
| `sheet.monthly` | Monthly operations | 1080 flowing | 4 + KPI row | 3 min | ops, finance, growth monthlies |
| `sheet.brief-card` | Brief card | 600 × 1000 fixed | 2 | 1 min | a single finding to share or print |

Sheet count in a delivery is one. A second sheet is a second delivery.

## Choosing

Compare all three on content structure, density, and reading speed, and write
the rejections. The name is not an industry lock: a monthly template carries a
weekly cadence or a quarterly board pack if the density matches. A fixed-size
sheet that does not fit the content is the wrong sheet; never shrink type or drop a
finding to make it fit.

## Slots

Every sheet has the same slot vocabulary, so content moves between them:

| Slot | Class | Carries |
|---|---|---|
| Eyebrow | `ch-sheet__eyebrow` | period, org, document type |
| Title | `ch-sheet__title` with one `<b>` | the page-level claim, one emphasised phrase |
| Lede | `ch-sheet__dek` | two sentences of context |
| KPI row | `ch-sheet__kpis` › `ch-kpi` | three to four numbers with a delta; pure typesetting, does not count as a chart |
| Section | `ch-sheet__kicker` → `ch-sheet__claim` → card | numbered finding, its sentence, its figure |
| Rail | `ch-sheet__rail` | about, method, definitions, source link |
| Foot | `ch-sheet__foot` | date, author, version |

Each chart inside a sheet is selected by `03-selection.md` on its own. The sheet's
layout is never a reason to bend a chart's honesty or floors.

## Procedure

1. Extract the page claim, the two to four findings with their sentences, the KPIs,
   the context paragraph, and the sources, before opening a template.
2. Copy the sheet file whole. Replace every slot. Remove any slot you do not fill;
   do not leave demo text, demo numbers, or a demo source anywhere (`grep` for the
   demo org name before delivery).
3. Lock the sheet's palette as the page palette. Every card inherits it.
4. Lint, view the whole page at 100%, confirm nothing overflows the measure, and
   confirm the reader can find the page claim in three seconds.
