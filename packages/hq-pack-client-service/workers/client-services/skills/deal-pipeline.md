---
name: deal-pipeline
description: Keep commercial stage honest. Stage lives in engagement.md as free text and is written there first; the CRM slot, if bound, receives an idempotent mirror keyed by the engagement's dedupe key. With the CRM slot unbound the skill answers pipeline questions by reading engagement records and makes no external writes.
args:
  - mode: "review | set-stage | mirror | dedupe-check"
  - scope: free-text target — one client slug, a segment, or 'all'
  - stage: free-text stage label for set-stage (never an enum — the firm's own words)
allowed-tools: Read, Write, Edit, Bash(bash core/workers/public/client-services/scripts/slot-state.sh:*), Bash(bash core/workers/public/client-services/scripts/engagement-layout.sh:*), Bash(ls:*)
---

# deal-pipeline — commercial stage, engagement-first

The engagement record owns stage. The CRM is a **derived, write-mostly mirror**
of it, and it is optional. This skill exists because the original version of it
assumed a deal-stage pipeline in a specific tool; a firm with no CRM has no
pipeline, and a firm with a contact-only CRM has no stages. Stage lives in
`engagement.md`; mirroring it is a bonus.

## Governing policies (load and honor)

- `client-service-engagement-is-source-of-truth`
- `client-service-internal-external-split`
- `client-service-approval-gate-external-actions`

## Step 0 — resolve the CRM slot. Always first, before any read or write.

```bash
bash core/workers/public/client-services/scripts/slot-state.sh --firm {firm} --slot crm
```

Branch on three states:

| State | What this skill does |
|---|---|
| `bound` | full path: engagement first, then the idempotent mirror (steps 1–4) |
| `empty` | **degraded path** (below). The firm has decided it runs no CRM. |
| `undeclared` | **degraded path** (below), reported as *not declared*, not as empty. |

### Degraded path — `empty` or `undeclared`

Say it in the report, in these words, naming which of the two states it is:

```
crm slot is not configured (<empty|undeclared>). No external writes were made.
```

Then:

1. Answer the pipeline question by **reading engagement records** —
   `companies/{firm}/clients/*/engagement.md`. That is where stage lives. This is
   a complete answer, not a fallback apology.
2. On `empty`, surface any `recommended:` hint **once**, as an option, never a
   requirement, and record the decline so you stop asking.
3. On `undeclared`, suggest `/onboard-firm` so the firm can answer the question,
   and do **not** record a decision it never made.
4. Make **no external writes**: no CRM call, no scratch file, no report that
   implies a mirror happened. `mode=set-stage` still writes the stage to
   `engagement.md` (that is the source of truth, not an external system) and then
   reports the mirror as skipped. `mode=mirror` with an unbound slot writes
   nothing at all and says why.
5. Exit successfully. An unbound slot is a supported end state, not an error.

## Steps (bound path)

1. **Write stage to `engagement.md` first.** Stage is **free text in the firm's
   own vocabulary** — this pack ships no stage enum and validates no label
   against a list. Record the label, the date, and the evidence behind the move.
   If the evidence is not in the engagement record, capture it there first.

2. **Derive the dedupe key locally, FOR THIS SLOT.** `resolve_dedupe_key` is
   **pure and local** — no tool call. Resolve it with the layout, never by
   assuming the slug, and always with `--slot`:

   ```bash
   bash core/workers/public/client-services/scripts/engagement-layout.sh \
     --firm {firm} --engagement {client_slug} --slot crm
   ```

   which also tells you the canonical `engagement_path` for this engagement.

   **The key is per slot, not per engagement.** `mapping.dedupe_field` names the
   remote *field* this tool joins on; `engagement_layout` resolves the *value*
   that goes in it, and a firm's slots may join on different shapes of value —
   a short alias in the ledger and the agreements tool, a registrable domain in
   the CRM. Reusing another slot's key here is the D1 defect: the lookup is
   rejected, the search-then-create in step 3 cannot match, and the "create"
   branch produces a **duplicate company record**. Read the resolved
   `dedupe_key_for_crm_source` and say which level it came from in the report.

   Precedence, most specific first — scope, then slot within a scope:
   per-engagement slot key → per-engagement general key → firm slot key → firm
   general key → `{slug}`.

   **`state: declared-none` means STOP for this slot.** The firm declared there
   is no join value here. Report the key as unresolved, make **no external
   write**, and say what would resolve it (declare
   `engagement_layout.dedupe_keys.crm` for this engagement). Never substitute
   another slot's key, the general key, or the slug: an unresolved key blocks a
   write, a wrong key creates a duplicate.

3. **Search, then create.** `upsert_company(key, company_profile)` and
   `upsert_deal(key, engagement_summary)`, with the **crm** key from step 2. One
   client, one company, one deal. A re-run must create zero duplicates — if you
   cannot search first, do not write.

4. **`mirror_stage` is an optional capability.**
   - declared in `mapping.capabilities` → call it with the free-text label;
   - `capabilities: []` (declared none) → skip without attempting;
   - key absent (undeclared) → attempt it and degrade gracefully on failure.
     Absent means unknown, not unsupported.

   **Translate the label first if the binding says to.** A firm's engagement
   vocabulary and its CRM's configured stage options are usually two different
   vocabularies; `mapping.stage_labels` maps the first to the second. A label
   with no entry passes through unchanged, an absent `stage_labels` means
   undeclared (pass everything through), and a rejected label is a warning —
   never invent a mapping and never rewrite `engagement.md` to match the tool.

5. **`read_back` is advisory only.** You may show a read-back to the operator. It
   may **never** overwrite `engagement.md`. The direction of truth is one-way.

6. **Failures are warnings.** A CRM error is reported and does not change
   engagement state, does not block, and does not fail the skill. Never retry a
   write without re-deriving the dedupe key.

7. **Never bulk-delete or bulk-mutate** without explicit, scope-confirmed
   approval naming what will change and how many records.

## What never crosses into the CRM

Firm-internal commentary — margin, likelihood, internal owner opinions,
back-channel notes from the engagement record's internal section. The mirror
carries stage, company profile and an engagement summary assembled from
client-safe sections. Nothing else.

## Done when

- The CRM slot state was resolved before anything else and reported by name.
- Stage exists in `engagement.md` first, in the firm's own words, with evidence.
- The join key was resolved **with `--slot crm`**, and the report names which
  precedence level it came from. A `declared-none` key stopped the write.
- On a bound slot: the mirror is idempotent and a re-run created zero duplicates.
- On an unbound slot: the report says which state it is, the pipeline question was
  answered from engagement records, and **nothing was written outside
  `engagement.md`**.
