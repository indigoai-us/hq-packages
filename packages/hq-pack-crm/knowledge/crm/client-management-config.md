# Per-company client-management config

The CRM and the bundled client-management skills are **company-agnostic**. What
differs per company — which systems back each GTM silo, who the owner is, where
meetings come from, what the pipeline stages are called — lives in one config
file, not in the skills.

This is the seam the `/crm` skill already implies ("which specific systems back a
company … are company configuration, not part of this skill"). `/crm-setup`
writes it; the bundled skills read it.

## Where it lives

`companies/{co}/client-management.yaml`

One file per company. It records **shape and references, never secret values**
(secrets live in `hq secrets`; connections live in
`companies/{co}/connections/{slug}.yaml`).

## Schema

```yaml
company: indigo                    # company slug
owner:                             # who "my action items / next steps" belong to
  name: "Stefan Johnson"
  entity: person/stefan-johnson    # ontology entity ref (optional)
  email: stefan@getindigo.ai

# The GTM silos. Each silo is either CONNECTED to a service (via /new-connection,
# referencing a connection slug) or BUILT native (records maintained directly in
# the ontology). Omit a silo the company doesn't use.
silos:
  inbound:                         # where leads originate
    mode: connected                # connected | native
    connection: neon-demo-requests # -> companies/{co}/connections/neon-demo-requests.yaml
  pipeline:                        # CRM of record (stage, owner)
    mode: connected
    connection: attio
  contracts:
    mode: connected
    connection: pandadoc
  billing:
    mode: connected
    connection: stripe
  mail:
    mode: connected
    connection: gmail-indigo
  meetings:
    mode: native                   # native = HQ meeting notes; or connect Recall/Fireflies
    source: hq-meeting-notes       # hq-meeting-notes | recall | fireflies

# Pipeline stage vocabulary for this company (drives /crm grouping + reports).
stages:
  - lead
  - demo
  - demo_done
  - proposal
  - signed
  - active

# Secret KEY NAMES the bundled skills may need (resolved via hq secrets exec).
# Never values. Usually mirrors the connections' `secrets`.
secrets:
  - INDIGO_GTM_HQ_LOCAL_ATTIO_API_KEY
  - STRIPE_SECRET_KEY
  - PANDADOC/API_KEY
  - SURVEY_DATABASE_URL
```

## How skills use it

Each bundled skill resolves config at the top of its run:

1. Read `companies/{co}/client-management.yaml`.
2. For a silo it needs, branch on `mode`:
   - `connected` → drive the referenced connection's capability (which reaches
     secrets via `hq secrets exec`).
   - `native` → read/write the ontology entities directly (via `/crm` reads and
     the `hq crm entity upsert` write path).
3. Use `owner` for "my"-scoped queries, `stages` for pipeline vocabulary, and
   `meetings.source` to pick the meeting backend.

A skill must **degrade gracefully** when a silo is absent: report "no billing
connected" rather than assuming Stripe.

## Field notes

- **`silos.*.mode: native`** is the zero-vendor path — the company has no
  external tool for that silo, so records live natively in the ontology. This is
  what makes the CRM work with no external services at all.
- **`silos.*.connection`** is a connection slug, resolving to
  `companies/{co}/connections/{slug}.yaml` (see the connections knowledge in
  `core/knowledge/public/connections/`).
- **`meetings.source`** decouples meeting-derived skills (signals,
  meeting-next-steps, standup) from any single meeting vendor.
- Keep this file in sync with the connection definitions: each `connected` silo
  should point at a real connection slug.
