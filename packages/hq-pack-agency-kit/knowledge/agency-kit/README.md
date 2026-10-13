# Agency Kit: how it fits together

The AI Builders Agency Kit is an operating system for a service agency inside
HQ. It sits on top of `hq-pack-client-service`, which provides the client
folders, engagement records and handover.

## The pieces

| Piece | What it is | Where it lives |
|---|---|---|
| Agency playbook | The agency's own standards: profile, onboarding checklist, audit criteria, scope rules, examples, learnings, default client workspace mode | `companies/{firm}/knowledge/agency-playbook/` |
| Engagement record | One source of truth per client (from client-service) | `companies/{firm}/clients/{slug}/engagement.md` |
| Client workspace | The standard layout around the engagement record: profile, access tracker, documents in, onboarding and reports out | `companies/{firm}/clients/{slug}/` |
| Client company (optional) | The client's own HQ, for client-facing work and handover | `companies/{client}/` |
| Brand | AI Builders palette, type and voice for what the pack shows students | `brand/` in the pack |

## Folder or company

Every client has a workspace folder inside the agency's company. That folder
is where the agency's internal record lives, in both modes.

- **folder** mode: the folder is the whole workspace. Use it for most clients.
- **company** mode: the client also gets its own HQ company. Use it when the
  client will run HQ themselves, needs their own team inside it, or will take
  the work with them at the end. The company is the isolation boundary and the
  handover boundary. Nothing internal is copied into it; firm skills reach it
  only through `/client-pack`.

The playbook holds the agency's default. `/client-workspace` asks per client.

## The flow

1. `/agency-setup`: once. Writes the playbook and runs `/onboard-firm`.
2. `/proposal`: before a client signs.
3. `/new-client`: when they sign. Creates the engagement record.
4. `/client-workspace`: the standard folders, and the folder-or-company choice.
5. `/client-onboarding`: right after signing. Scope review, missing inputs,
   account audit, kickoff package, then playbook learnings.
6. `/scope-check` and `/weekly-update`: through the engagement.
7. `/handover-client`: if the client gets their own HQ at the end.

`/practice-client` runs steps 3 and 5 on invented data.

## Working across clients in one session

An HQ session is locked to one company by default. The agency's own company
holds everything the kit needs, so most work never leaves it.

When a task needs a client's own HQ company too, add it to the session:

```bash
hq core hq-session add company {client}
hq core hq-session get company_slugs
hq core hq-session remove company {client}
```

Requires hq-core 16.0.4 or newer (its CLI floor is hq-cli 5.345.67) and the
`hooks.multi-company-session-lock` setting enabled for the agency's company by
an HQ administrator. Every company not added stays blocked. Remove a client
when you are done with it.

Rules that still apply in a multi-company session:

- Firm-internal notes never get copied into a client's company.
- Firm skills and knowledge reach a client's company by materializing a firm
  pack (`/client-pack`), not by reading across companies.
- Lessons go into the firm's playbook, not the client's company.
