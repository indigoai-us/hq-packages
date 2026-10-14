# {{CLIENT_NAME}}: client workspace

Workspace for {{AGENCY_NAME}}'s work with {{CLIENT_NAME}}. Created {{TODAY}}
by `/client-workspace` in **{{WORKSPACE_MODE}}** mode.

| File or folder | What goes there |
|---|---|
| `engagement.md` | The engagement record: stage, terms, contacts, decisions. Source of truth. Written by `/new-client`. |
| `client-profile.md` | Who the client is, what they sell, their goal, and how they want to work with us. |
| `access-and-assets.md` | Every account, login, asset and approval contact we need, and whether we have it. |
| `onboarding/inputs/` | Documents the client gave us: contract, proposal, call notes, exports. |
| `onboarding/` | What `/client-onboarding` produces: brief, intake request, audit, kickoff package, status. |
| `reports/` | Weekly updates and monthly reports, one file per report. |

## Modes

- **folder**: this folder inside the agency's company is the whole client
  workspace. Nothing about the client lives anywhere else.
- **company**: this folder holds the agency's internal record, and the client
  also has its own HQ company at `companies/{{CLIENT_SLUG}}/` for client-facing
  work and handover. Nothing internal is copied there.

Internal notes stay here in either mode. Anything a client will see is drafted
here and approved by a strategist before it goes out.
