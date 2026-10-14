# examples/

Fixtures for `../scripts/validate-config.sh`, and the record of the two-firm
schema walk that froze the contracts in US-002.

| File | Shape | Expected |
|---|---|---|
| `firm-a.yaml` | fully bound — all five slots wired to tools | PASS, 0 warnings |
| `firm-b.yaml` | mostly empty — three slots unbound, portal on a SaaS project tool, transcripts on a document pointer | PASS, 0 warnings |
| `broken.yaml` | four planted contract faults | FAIL with four named error codes, exit 1 |

```bash
bash ../scripts/validate-config.sh firm-a.yaml
bash ../scripts/validate-config.sh firm-b.yaml
bash ../scripts/validate-config.sh broken.yaml   # exits 1
```

**Hard rule:** every example references secrets by **vault name only**. No secret
values, tokens, keys, account ids, template UUIDs, or live URLs land in this
directory. Firm names are de-branded; `firm-a` and `firm-b` are fictional slugs.

## Second-firm schema walk — done (US-000 / decision D2)

The contracts were walked against **two real firms' stacks**, not one. `firm-a`
is the de-branded shape of the firm the lifecycle was originally proven on: every
slot filled, a CRM with a real pipeline, a firm-owned client site, automated call
capture. `firm-b` is the de-branded shape of the second validation firm: **no
CRM, no billing tool, no agreements tool**, a client-facing surface that is a
SaaS project tool rather than a repo, and a call record that is a document a
human maintains.

The walk changed the contracts. Each gap it surfaced and how the frozen contract
discharges it:

| # | Gap found in the walk | How the contract closes it | Where to see it |
|---|---|---|---|
| 1 | Empty slots were only expressible by absence, so "no CRM" and "never asked" looked identical | Three-state resolution — `bound` / `empty` / `undeclared`. `empty` is written positively as `binding: null`; absence resolves to `undeclared` and is warned about, never treated as a decision | `firm-b.yaml` crm/billing/agreements; validator prints the state of every slot |
| 2 | The portal contract was repo-shaped (`build`, `deploy`), which no project-tool firm can implement | Operation-shaped only: `publish_update`, `share_artifact`, `portal_status`. A repo-backed portal hides build and deploy inside its binding | `firm-a` binds a site CLI, `firm-b` binds a project tool — same three operations |
| 3 | Nothing covered where work product lives (a design tool for one firm, a generated pack for the other) | **Resolved: the portal contract absorbs it via `share_artifact`; no `deliverables` slot in v1.** The pack records and shares references, and explicitly does not store, upload, render, version, or approve assets | `adapter-contracts.md` § "Where work product lives — resolved, not deferred" |
| 4 | CRM operations assumed a deal-stage pipeline exists | `engagement.md` stays the source of truth; the CRM is a derived, write-mostly mirror. `set_stage` became the **optional** `mirror_stage` capability with a free-text label, and no skill may block on the CRM | `firm-a` declares `mirror_stage`; `firm-b` has no CRM at all and still runs |
| 5 | Transcripts assumed a capture service | A slot may be bound by a **pointer** (`kind`/`location`/`maintained_by`) instead of a tool. A pointer is a bound state; operations a static location cannot serve resolve as unsupported | `firm-b.yaml` transcripts |

## Compatibility checks run against these fixtures

Beyond the three headline cases, the validator was exercised on derived fixtures
to prove policy `hq-absent-field-never-means-constraining-value` holds in both
version directions:

- slot key deleted → resolves `undeclared` (not `empty`), warns, still passes;
  `--strict` promotes it to a failure for `/onboard-firm`'s own output
- slot present with no `binding` key → `undeclared`, warns, still passes
- config from a newer pack version (unknown top-level key, unknown slot, unknown
  capability, unknown binding field) → four warnings, still passes
- newer **major** `schema_version` → named `E_SCHEMA_VERSION_UNSUPPORTED_MAJOR`,
  not a parse crash
- `recommended.required: true` → named `E_RECOMMENDATION_REQUIRED_TRUE`; a
  recommendation can never become a requirement
- a valid config with one field broken (`connector: mcp` → `webhook`) → fails,
  proving the validator discriminates rather than passing everything
