# GBrain In HQ

GBrain is best treated as an optional memory engine behind HQ, not as HQ core.

HQ remains responsible for:

- Company resolution and tenant isolation
- Policies and skills
- Worker routing
- Secrets and vault access
- Sync and sharing

GBrain adds:

- Brain-first lookup before external research
- Synthesized answers with citations and gaps
- Entity and relationship traversal
- Durable capture of decisions, meetings, people, companies, and projects
- Background memory maintenance

## Default Mapping

| HQ concept | GBrain shape |
|---|---|
| `companies/{co}/knowledge/` | Company brain source material |
| `companies/{co}/company-brief.md` | High-signal company context |
| `companies/{co}/ontology/` | Optional entity pages |
| `workspace/gbrain/{co}` | Runtime `GBRAIN_HOME` |
| `core/scripts/hq-gbrain` | Company-bound wrapper |

## Recommended Schema Types

Start with the bundled GBrain schema. Add HQ-specific types only after the
company corpus proves they matter:

- `person`
- `company`
- `project`
- `meeting`
- `decision`
- `action-item`
- `policy`
- `worker`
- `repo`
- `artifact`

Small corpora should not overfit early. Use `gbrain schema detect` and
`gbrain schema review-orphans` after a real import before adding types.

## Interaction Pattern

Use GBrain where the user wants state of play, not raw file hits:

```bash
core/scripts/hq-gbrain search indigo "security review"
core/scripts/hq-gbrain ask indigo "what do we know about Apex?"
core/scripts/hq-gbrain capture indigo "Decision: keep GBrain isolated per company."
```

For exact file search, continue using `qmd` or `rg`.
