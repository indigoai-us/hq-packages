---
id: hq-deck-slide-reorder-three-coordinated-edits
title: Reordering a slide in a self-contained HTML deck requires three coordinated content-match reorders
scope: global
trigger: reordering one slide in a self-contained HTML deck that embeds presenter notes
when: (deck || slide) && (reorder || notes-data || teleprompter || renumber || script)
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-06-26
updated: 2026-06-26
source: session-learning
tags: [frontend]
---

## Rule

ALWAYS: reordering one slide in a self-contained HTML deck that embeds presenter notes requires THREE coordinated reorders by content-match (not positional index): (1) the deck <article>s — reorder + renumber data-i AND the hardcoded 'NN / TOTAL' page-num; (2) the embedded <script id=notes-data> 'slides' array — reorder entries so spoken/bullets/thumb travel with the slide, then renumber each 'n'; (3) the SCRIPT.md sections + regenerate the teleprompter. Missing any one desyncs the notes from the deck.

## Rationale

A self-contained presenter deck holds the same slide ordering in three independent places: the visible deck markup (<article> elements with data-i and a hardcoded 'NN / TOTAL' page number), the embedded notes payload (<script id=notes-data> with a 'slides' array carrying spoken text, bullets, and thumbnails per slide), and the external SCRIPT.md that feeds the teleprompter. Reordering by positional index is fragile because the three structures don't share indices cleanly; matching by content keeps the right spoken notes and thumbnail attached to the right slide. Any one of the three left un-reordered (or un-renumbered) silently desyncs the presenter notes from what's on screen. Captured from the AI Summit keynote deck.
