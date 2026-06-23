# Enabling CRM for a company

CRM is **off by default** and gated per company by the **`crmEnabled`** company
setting.

## Turning it on

`crmEnabled` lives in the company's settings (managed in `hq-pro`'s
`CompanySettings`, surfaced in the HQ console). When enabled for a company:

- the CRM engine's read-only adapters run for that company;
- each account is stamped with its `external_ids` and source legs;
- `crm-projection.json` is generated and synced into the company vault;
- the `crm_*` read surface (and the `/crm` skill) return data for that company.

## Prerequisites

- The company must have ontology entities to project (at minimum `company`
  accounts).
- The source-system credentials the company's adapters need live in the company
  vault (accessed via `hq secrets`), never inline.

## Checking status

If a company has **no `crm-projection.json`**, CRM is either not enabled or has
not synced yet:

1. Run `/hq-sync` for the company.
2. If the projection is still absent, enable `crmEnabled` in the company
   settings.

Do not silently fall back to a live hand-join of source systems — report that CRM
isn't enabled/synced for the company instead.

## Scope

CRM data is strictly per-company and vault-scoped. Never read or join one
company's CRM data into another's context — cross-company CRM use is a tenant
boundary violation.
