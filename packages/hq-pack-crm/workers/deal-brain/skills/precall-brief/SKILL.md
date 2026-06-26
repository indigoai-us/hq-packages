---
name: precall-brief
description: Assemble a pre-call war room for a prospect from a company's entire GTM memory — the positioning that fits, proven objection rebuttals (cited to the call they landed in), a recommended demo/call path, and opening lines. Company-agnostic; resolves the corpus from the active company's qmd collections and client-management.yaml.
allowed-tools: Bash, Read, Grep
---

# Pre-call brief — Deal Brain

Assemble a **pre-call war room** for a named prospect, grounded in the company's
real sales-conversation memory. Receipts, not vibes — every claim cites the call
or doc it came from.

## Resolve context first

1. Active company `{co}`. Read `companies/{co}/client-management.yaml` for
   `owner`, `stages`, and `silos.pipeline`.
2. The memory corpus = the company's qmd collections (from `manifest.yaml`
   `qmd_collections`): the company collection, plus its `-meetings` and
   `-signals` collections where they exist. **Search only `{co}`'s collections**
   — cross-company retrieval is a category-1 violation.

## Build the brief

1. **Who they are / deal state.** Pull the prospect's account from the pipeline
   silo (connected → the connection's read capability via `hq secrets exec`;
   native → `/crm`): company, contacts, current stage (in the company's own
   `stages` vocabulary), open deal + value.
2. **What's been said.** `qmd search "<prospect / company / topic>" -c {co}-meetings -n 8`
   across prior calls; pull surrounding context with `qmd get <file>:<line>`.
   Summarize the through-line: what they care about, what's stalled.
3. **Objections + rebuttals that landed.** For each objection this prospect (or
   similar buyers) raised, surface the rebuttal that has actually worked, cited
   to the call/buyer it landed with (`-c {co}-meetings` / `-c {co}-signals`
   key_points). If the corpus has nothing, say so — never fabricate.
4. **Positioning that fits.** Use the company's CURRENT positioning as found in
   its knowledge corpus (`-c {co}`). Don't invent claims or use language the
   corpus doesn't support.
5. **Recommended call path + opening lines.** A stage-appropriate plan and two or
   three opening lines grounded in the above.

## Output

```markdown
# Pre-Call War Room — {Prospect / Company}

**Stage:** {stage} · **Deal:** {value if any} · **Owner:** {owner}

## The through-line
- {what they care about / what's stalled — cited}

## Objections & proven rebuttals
- **"{objection}"** → {rebuttal} — _landed with {buyer}, call {meeting-id}_

## Positioning that fits
- {claim} — _{source}_

## Call plan
1. {opening} 2. {value beat} 3. {advance-the-deal ask}

## Opening lines
- "{line}"
```

## Rules

- **Tenant isolation:** only `{co}`'s collections; never `qmd search` across all.
- **Cite everything:** no quote or "this works" claim without the call/doc it
  came from.
- **Draft, don't send:** this produces a brief. Sending or CRM writes need
  explicit human approval.
