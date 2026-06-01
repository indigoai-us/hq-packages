# @indigoai-us/hq-pack-gbrain

Optional GBrain integration for HQ.

This pack keeps HQ as the orchestrator and uses GBrain as an optional per-company
brain runtime. It does not change HQ core behavior on install. Users opt into a
company brain with:

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-gbrain
bash core/scripts/scan-packages.sh
core/scripts/hq-gbrain setup indigo --install-gbrain
```

## What it ships

| Surface | Purpose |
|---|---|
| `/gbrain` | User-facing skill for setup, status, search, ask, capture, and doctor flows |
| `core/scripts/hq-gbrain` | CLI wrapper that binds `GBRAIN_HOME` to `workspace/gbrain/{company}` |
| `gbrain-company-isolation` | Hard policy: never share one GBrain home across companies |
| `gbrain-hq` knowledge | Conceptual mapping between HQ companies and GBrain sources/schema |
| `gbrain-gardener` worker | Starter worker for future background stale/contradiction/gap checks |

## Design

- One company maps to one `GBRAIN_HOME`.
- Runtime DB state lives under `workspace/gbrain/{company}`.
- Company source material stays in its existing HQ paths.
- GBrain is installed and initialized only when a user or test runs setup.
- Imports default to `--no-embed` so the pack can be smoke-tested without API keys.

## Smoke Test

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-gbrain
bash core/scripts/scan-packages.sh
core/scripts/hq-gbrain status indigo
core/scripts/hq-gbrain setup indigo --install-gbrain
core/scripts/hq-gbrain search indigo "security"
```
