---
name: crm-setup
description: Stand up HQ's native CRM for a company, end to end — connect the services it already uses or build native HQ capabilities for the ones it doesn't, then turn the CRM on. Use when the user says "set up the CRM", "onboard <company> to the CRM", "turn on CRM for <company>", "get our pipeline into HQ", or is starting client management in HQ. Service-agnostic: no vendor is required. Writes companies/{co}/client-management.yaml, wires each GTM silo via /new-connection or a native-entity capability, enables crmEnabled, syncs, and verifies /crm returns data.
allowed-tools: Bash, Read, Write, Edit, Grep, AskUserQuestion, Skill, Agent
---

# /crm-setup — stand up the CRM for a company

Walk a company from zero to a working canonical CRM. The CRM is HQ's ontology
used as the canonical client record; external systems are **optional enrichment**.
So this works whether the company has a full GTM stack or no tools at all.

The promise: **if you use a tool, we connect it; if you don't, we build the
capability natively in HQ.** No vendor is required.

## Prerequisites

- A resolved company slug `{co}` (ask if not given).
- The caller is an owner/member of the company (CRM enable is owner-gated).
- The `hq` CLI on PATH (for activation + sync).

## Step 1 — Frame the silos

The CRM joins up to six **GTM silos** onto each client record. Explain them
plainly and find out, for each, whether the company uses a tool:

| Silo | What it holds | Common tools |
|------|---------------|--------------|
| inbound | where leads originate | a lead DB, a demo-request form, a survey DB |
| pipeline | CRM of record: stage, owner | Attio, HubSpot, Salesforce, a spreadsheet |
| contracts | agreements / signing state | PandaDoc, DocuSign |
| billing | invoices / subscriptions | Stripe, QuickBooks |
| mail | outreach + replies | Gmail, Outlook |
| meetings | call notes → activity timeline | HQ meeting notes, Recall, Fireflies |

Use AskUserQuestion (one or two grouped questions) to learn, per silo: **tool, or
none?** Don't force a tool — "none" is a first-class answer and routes to the
build-native path.

## Step 2 — Per silo: connect or build

For each silo the company cares about:

- **Has a tool → connect.** Invoke `/new-connection` (core) scoped to the
  company for that system. It picks the fastest harness, stores creds safely,
  writes `companies/{co}/connections/{slug}.yaml`, and returns a **connection
  slug**. Record the silo → connection slug mapping.
- **No tool → build native.** The company will maintain that silo's records
  directly in the ontology — no vendor. Scaffold a thin native-entity capability
  (a `connect-{silo}` skill or a `/newworker` worker) that creates/updates the
  relevant entities via the write path:
  ```
  hq crm entity upsert --company {co} --type <company|deal|contract|invoice> \
    --name "<name>" [--json <file>]
  ```
  `hq crm entity upsert` writes through the CRM write-gate and refreshes the
  projection, so native records are immediately queryable by `/crm`. This is the
  zero-vendor path that makes the CRM usable with no external services.

Default every silo to **read-only / least-privilege**; writes are
confirmation-gated (the `/new-connection` and secure-sidecar discipline).

## Step 3 — Write the config

Write `companies/{co}/client-management.yaml` capturing: the company, the owner
identity (for "my action items / next steps"), each silo's `mode`
(connected|native) + connection slug or native source, the pipeline `stages`
vocabulary, and the secret **key names** in play (never values). Schema +
field notes: the `client-management-config` knowledge doc.

This file is the parameterization seam every bundled client-management skill
reads — it is what makes them company-agnostic.

## Step 4 — Ensure there are accounts to project

The projection needs at least `company` account entities to show anything.

- If a `pipeline`/`inbound` silo is **connected**, the company's adapter (or the
  connection capability) supplies accounts.
- If silos are **native**, create a couple of `company` entities now via
  `hq crm entity upsert` so the projection isn't empty.

## Step 5 — Turn the CRM on

CRM is off by default, gated per company by `crmEnabled` (owner-callable). Enable
it from the terminal:

```
hq company settings set --company {co} --crm-enabled true
```

(Equivalent to the owner flipping it in the HQ console. Requires owner role.)

## Step 6 — Sync and verify

1. `/hq-sync` for the company so the projection (`crm-projection.json`) builds +
   lands in the vault.
2. Run `/crm` — confirm it returns accounts (by stage) and a real client's joined
   record. If the projection is missing, re-check: accounts exist? crmEnabled on?
   sync ran? Report which, rather than hand-joining sources as a silent fallback.

## Step 7 — Report

Summarize plainly: which silos are connected (and to what) vs native, that CRM is
enabled, and that `/crm` is live. Point the user at the bundled skills they can
now use (signals, action-items, meeting-next-steps, deal-brain,
client-engagement) — all driven by the config you just wrote.

## Rules

1. **No vendor is required.** "None" is a valid answer for any silo and routes to
   the build-native path. Never block setup on a tool the company doesn't have.
2. **Connect via `/new-connection`, don't hand-roll.** Reuse the core connection
   command for every connected silo so creds, capability, and the connection
   definition are handled consistently.
3. **Native writes go through `hq crm entity upsert`.** Don't write entity
   markdown by hand and hope the projection updates — it only refreshes on the
   write path.
4. **Least-privilege, read-first.** Read access by default; gate writes.
5. **Secrets only via hq.** Never paste or print a secret; `/new-connection`
   owns the safe credential flow.
6. **Per-company isolation.** Everything written stays in `{co}`'s scope; never
   pull another company's CRM data into setup.
7. **Verify before declaring done.** Setup isn't complete until `/crm` returns
   real data for the company.

## Reuse map

| Step | Use |
|------|-----|
| Connect a silo's service | `/new-connection` (core) |
| Build a native silo | `hq crm entity upsert` + `/newworker` (capability) |
| Enable CRM | `hq company settings set --crm-enabled true` |
| Sync + verify | `/hq-sync`, then `/crm` |
| Config schema | `client-management-config` knowledge doc |
