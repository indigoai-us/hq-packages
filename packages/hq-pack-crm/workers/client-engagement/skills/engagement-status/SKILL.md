---
name: engagement-status
description: Summarize where a client stands across their lifecycle — pipeline stage, last touch, open items, and contract/billing state — joined read-only from the company's configured GTM silos, with the cross-source flags that mean someone needs to act. Company-agnostic; resolves every silo from companies/{co}/client-management.yaml. Read-first; any external side effect is confirmation-gated.
allowed-tools: Bash, Read, Grep
---

# Engagement status — Client Engagement

Answer **"where does this client stand?"** by joining the company's GTM silos
onto one read-only picture: pipeline stage and health, last touch, open items,
and contract/billing state — plus the cross-source flags that mean someone needs
to act. Across the whole book, it's a status board; for one client, it's a
standing.

## Resolve context first

1. Active company `{co}`. Read `companies/{co}/client-management.yaml` for:
   - **`owner`** — for "my clients" scoping.
   - **`stages`** — the company's own pipeline vocabulary.
   - **`silos`** — which backend holds each dimension:
     - `pipeline` → stage, owner, account/deal.
     - `contracts` → agreement / signing state.
     - `billing` → invoices / subscriptions (may be absent).
     - `mail` / `meetings` → recent-touch, for staleness.
2. **Search only `{co}`'s** corpus and connections — cross-company retrieval is a
   category-1 violation.

## Read each silo (read-first, defensive)

For each silo you need, branch on `mode`:

- **`connected`** → drive the referenced connection
  (`companies/{co}/connections/<slug>.yaml`) read capability, reaching
  credentials only via `hq secrets exec` (never inline, never printed).
- **`native`** → read the ontology via `/crm`.
- **absent** → report it ("no billing connected") — never assume a vendor.

A silo failing (bad key, API blip) degrades that cell to `unknown` and is listed
under **Source notes** — it never crashes the run and is never silently read as
"fine."

## Compute the flags (the point of the tool)

Join across silos, in the company's own vocabulary:

- **active-but-unsigned** — declared active in `pipeline`, no completed
  agreement in `contracts`.
- **invoice-unsent** — latest invoice in `billing` is a draft (created, not
  sent).
- **invoice-overdue** — latest invoice is open and past due.
- **active-but-uninvoiced** — active client with no invoice yet.
- **stale-engagement** — no recent touch in `mail`/`meetings` beyond the
  company's threshold.

State each flag with the silos it was joined from.

## Output

```markdown
# Engagement status — {Client}

**Stage:** {stage} · **Owner:** {owner} · **Last touch:** {date / what}

| Dimension | State | Source |
|---|---|---|
| Pipeline  | {stage / health}        | {pipeline silo} |
| Contract  | {signed / sent / draft / —} | {contracts silo} |
| Billing   | {latest invoice + status} | {billing silo or "—"} |
| Open items| {what's outstanding}    | {pipeline / activity} |

## Flags
- {flag} — _joined from {silos}_

## Source notes
- {any silo that degraded to unknown, and why}
```

For the whole-book view, emit one row per active client; **digest** mode lists
only clients carrying a flag.

## Rules

- **Read-first.** This skill only reads. Any external side effect — drafting or
  creating an agreement, writing to the CRM, syncing/deploying a client portal,
  anything that sends/spends/publishes — is **confirmation-gated**: present the
  exact action and wait for explicit approval. No autonomous side effects.
- **Tenant isolation:** only `{co}`'s config, connections, and collections.
- **Degrade gracefully:** an absent or failing silo is reported, never assumed.
- **Secrets only via `hq secrets exec`:** never read, print, or inline a
  credential.
- **Never invent terms.** Any number reported comes from the silo or the
  canonical engagement record — not a guess.
