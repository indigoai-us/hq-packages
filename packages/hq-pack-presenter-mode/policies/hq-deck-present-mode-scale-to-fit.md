---
id: hq-deck-present-mode-scale-to-fit
title: Add present-mode scale-to-fit to fixed-px slide decks (min(innerWidth/W, innerHeight/H))
scope: global
trigger: a fixed-px-designed slide deck renders small with empty margins on a larger screen or projector
when: (deck || slide || present) && (scale || fit || projector || resize || 1280 || 720)
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

ALWAYS: a fixed-px-designed slide deck (e.g. base 1280x720) renders small with empty margins on a bigger screen/projector because content doesn't scale. Add a present-mode scale-to-fit: make the active slide a fixed 1280x720 box at top:50%/left:50% with transform: translate(-50%,-50%) scale(var(--fit)) overflow:hidden, set --fit = min(innerWidth/1280, innerHeight/720) on enter+resize, and FIRST pin any vw/vh units in slide content to px or they fight the scaling. 720p stays --fit=1 (unchanged); 1080p becomes a clean 1.5x.

## Rationale

A deck authored at a fixed pixel base (1280x720) is laid out for exactly that viewport, so on a larger display the content keeps its 1280x720 footprint and floats inside empty margins instead of filling the screen. Wrapping the active slide in a centered 1280x720 box and applying transform: scale(var(--fit)) with --fit = min(innerWidth/1280, innerHeight/720) uniformly scales the whole slide to fill the available space while preserving aspect ratio (letterboxing only the leftover dimension). Pinning vw/vh units to px first is required because those units are resolved against the real viewport, not the scaled box, so they fight the transform and break the layout. At native 720p the ratio is 1 so nothing changes; a 1080p projector cleanly gets 1.5x. Captured from the AI Summit keynote deck.
