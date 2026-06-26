---
id: agent-browser-ui-verification
title: "Verify UI changes in a real browser with agent-browser"
scope: global
trigger: UI change, frontend verification, browser testing, "verify the page", E2E
when: testing
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: soft
created: 2026-06-03
tags: [testing, frontend]
---

## Rule

`agent-browser` is the preferred tool for confirming a frontend change actually works in a
real browser — not just that the code compiles or unit tests pass. Installed globally as a
native binary it starts roughly 150x faster than `npx` (it runs the Rust binary directly
instead of resolving and fetching the package each call), so per-step browser verification is
cheap enough to do routinely. Install once (see Prerequisites in the HQ README:
`brew install agent-browser`).

When a task involves a visible UI change (a page, component, form, layout, or interaction):

1. **Load the command reference first.** Run `agent-browser skills get core --full` before
   driving the browser. The skills ship version-matched with the CLI and include workflow
   patterns, selector/ref usage, and copy-paste examples — prefer this over guessing commands
   from flag docs. Specialized skills exist for Electron, Slack, and exploratory testing
   (`agent-browser skills list`).
2. **Drive the browser to verify the change** — navigate to the page, exercise the changed
   interaction, and confirm the observed behavior matches intent before reporting the change
   as done. This satisfies the HQ "E2E proves it works" principle for UI work.
3. **Confirm data/context before filing a bug** — for data-dependent pages, verify the API is
   reachable and the page genuinely lacks a feature (vs. just lacking data context) before
   reporting an empty or broken page; cross-reference the page source. React controlled
   components may not re-render on a raw `click` — try semantic locators or verify the DOM
   directly first.

## Rationale

Running agent-browser as a global native binary instead of via `npx` removes per-invocation
package resolution, making browser verification fast enough to do on every UI change rather
than assumed correct from a green build. Folding the false-positive guidance (check data
context, React state, source cross-reference) inline keeps UI bug reports trustworthy without
depending on a separate operator-personal policy.
