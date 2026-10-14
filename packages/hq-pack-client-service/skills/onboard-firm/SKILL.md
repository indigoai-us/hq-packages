---
name: onboard-firm
description: One-time onboarding for a firm installing hq-pack-client-service. Detects the tools the firm already uses (company settings, configured MCP servers, vault secret NAMES), writes companies/{firm}/client-service.yaml binding each adapter slot — crm, billing, agreements, portal, transcripts — and scaffolds clients/ plus clients/_templates/engagement.template.md. Idempotent; empty slots stay empty with an optional recommendation. Run once after install.
triggers:
  - onboard firm
  - set up client service
  - configure client-service.yaml
  - bind my crm and billing tools
  - install client service pack into this company
maturity: HQ-native (authored for this package)
---

# Onboard Firm

Run this once after `hq packages install hq-pack-client-service --company <co>`.
It binds the pack to the **company that installed it**. It does **not** create a
tenant: no `/newcompany`, no `/onboard`, no new company slug. If the installing
company is ambiguous, ask — never guess, and never scaffold a new one. The engine
refuses outright (`E_COMPANY_NOT_FOUND`) if `companies/{firm}/` does not exist.

Everything below writes under `companies/{firm}/`.

## What onboarding is actually deciding

Five adapter slots — `crm`, `billing`, `agreements`, `portal`, `transcripts` —
each of which ends in exactly one of three states. The distinction is the whole
point of the exercise, so keep it straight while you run this:

| State | Written as | Means |
|---|---|---|
| `bound` | `binding:` mapping, or `pointer:` | the firm runs something here |
| `empty` | **`binding: null`, written explicitly** | the firm decided it runs nothing here |
| `undeclared` | slot key absent | nobody has answered yet — unknown |

**`empty` is never inferred from absence, and `undeclared` is never reported as
`empty`.** A firm that has no CRM writes `binding: null` and means it; a config
that simply predates the question stays undeclared and gets asked. Full contract:
`knowledge/client-service/adapter-contracts.md` (frozen, US-002).

An install where all five slots are empty is fully supported. Every lifecycle
skill degrades to a documented local behaviour and keeps working.

## Hard rules

- **Secret NAMES only.** Onboarding reads the names of vault secrets. It never
  reads, resolves, prints, logs or writes a secret VALUE, and never calls
  `hq secrets get`, `--reveal`, `exec`, `env`, or `hq run`. A credential value
  in `client-service.yaml` is a validation error, not a style problem.
- **Never clobber.** A slot already `bound` or already `empty` is preserved
  exactly. Only `undeclared` slots are written.
- **Vendor names are configuration, never contract.** The only vendor names this
  pack emits are `recommended.tool` hints on empty slots (Attio for `crm`, Stripe
  for `billing`). Nothing branches on them.
- **A recommendation can never be required.** `recommended.required` is written
  `false` and the validator rejects `true`.
- **No auto-select of `_`-prefixed directories.** This skill creates
  `clients/_templates/`; any listing of `clients/` excludes leading-underscore
  entries by a general rule, never by naming `_templates`.

## Step 1 — Resolve the firm and detect what it already has

```bash
bash core/packages/hq-pack-client-service/scripts/detect-tools.sh --company {firm}
```

This scans three sources and reports each one's status separately:

| Source | What it reads | Transport it implies |
|---|---|---|
| `companies/{firm}/settings/` | entry names | none — unknown |
| MCP config (`settings/mcp.json`, `.mcp.json`) | `mcpServers` keys | `mcp` |
| vault secret **names** (`hq secrets list`) | names only, never values | `api` |

Read the `sources:` block before you read the candidates. `status: unavailable`
means **not scanned**, which is unknown; it never means "the firm has no such
tool". If the vault listing was unavailable, say so to the user rather than
concluding they have no billing tool.

A candidate whose evidence carries no transport (settings-only) is reported
`auto_bindable: false`. That is a question for the user, not a guess.

## Step 2 — Ask about what detection could not settle

Use `AskUserQuestion`, one question per call. Ask about exactly three things:

1. **Ambiguous slots** — more than one candidate, or a candidate with an unknown
   transport. Offer the candidates plus "none of these" plus "leave undecided".
2. **Empty slots that carry a recommendation** — surface it **once**, clearly
   marked optional, and make declining the obvious, cost-free answer. Suggested
   framing: *"No CRM was detected. You can wire one later; every skill works
   without it. Want a suggestion, or leave this slot empty?"* Declining is a
   supported permanent end state, not a deferral.
3. **Anything the user wants to override** from the detected plan.

Do not ask about slots already bound or already empty in an existing config —
they were answered on a previous run and re-asking is the bug this step exists to
avoid.

If a slot is a *place* rather than a tool — call notes in a document a human
maintains, say — that is a `pointer` binding (`kind` + `location`), which is a
**bound** state. The engine does not write pointers; add it by hand after the run
and re-validate. See the contracts file.

## Step 3 — Apply

Feed the answers to the engine. It never prompts, so every decision is explicit:

```bash
bash core/packages/hq-pack-client-service/scripts/onboard-firm.sh \
  --company {firm} \
  --bind crm=<label>:<mcp|cli|api>[:<VAULT_SECRET_NAME>] \
  --empty billing \
  --skip portal
```

| Flag | Effect |
|---|---|
| `--bind <slot>=<tool>:<connector>[:<SECRET_NAME>]` | bind the slot |
| `--empty <slot>` | write `binding: null` — a decision |
| `--skip <slot>` | leave undeclared — unknown, asked again next run |
| `--no-auto` | decide nothing that was not passed explicitly |
| `--non-interactive` | auto-resolve everything unspecified (the default) |
| `--dry-run` | print the plan, write nothing |

Auto-resolution, for anything you did not pass:

- exactly one auto-bindable candidate → **bind it**
- zero candidates → **empty**, plus the optional recommendation if one exists
- two or more candidates, or transport unknown → **left undeclared** and
  reported as needing a decision. Nothing is assumed.

The engine then writes `companies/{firm}/client-service.yaml`, scaffolds
`clients/` and `clients/_templates/engagement.template.md`, and validates its own
output with `validate-config.sh`. It exits non-zero if what it wrote does not
validate.

Unattended installs can run Step 3 alone with `--non-interactive` and take the
defaults; the result is a valid config with detected tools bound and everything
else explicitly empty.

## Step 4 — Confirm, honestly

Report to the user:

- each slot and its resulting state, with `empty` and `undeclared` named
  distinctly — never collapsed into "not set up";
- which recommendations were surfaced and declined (recorded in the slot's
  `notes`, so onboarding offers them once rather than every run);
- any detected credential name that could **not** be written because it does not
  match the schema's `secret_name` pattern — the slot is still bound, but the
  name has to be added by hand;
- whether `--strict` came back clean. Not clean means at least one slot is still
  undeclared: tell the user which, and that re-running answers it.

Then point them at `/new-client` for the first engagement.

## Re-running

Safe, and expected. A second run with the same inputs makes **zero** edits and
leaves the file byte-identical — nothing written carries a timestamp, precisely
so that is true. Re-run after installing a new tool, or after a pack upgrade adds
a slot: the new slot is undeclared, so onboarding asks about it and leaves every
existing answer alone.

## Degrading

If `yq` is missing the engine stops with `E_ENV_YQ_MISSING` rather than writing a
partial config. If the vault listing is unreachable, detection reports that
source `unavailable` and onboarding proceeds on the other two — but say so, and
consider re-running once the vault is reachable, because a slot marked empty on
the strength of a scan that never happened is the one failure mode this whole
design exists to prevent.

## Depends on

- `knowledge/client-service/adapter-contracts.md` — the slot contracts (frozen).
- `knowledge/client-service/client-service.schema.yaml` — the machine-readable schema.
- `scripts/detect-tools.sh` — detection.
- `scripts/onboard-firm.sh` — the non-interactive engine.
- `scripts/validate-config.sh` — the gate the written config must pass.
