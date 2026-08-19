# Work mesh (pack)

Dogfood layer so any HQ install can join the live work mesh before this lands in hq-core.

## Pieces

| Piece | Role |
|---|---|
| `hq-work-mesh.sh` / `.mjs` | start / progress / story / **listen** (cache writer) |
| `genesis.sh` | thread + ensure-project + PROJECT_VIEW PUT |
| `install-listen.sh` | isolated `~/.hq/work-mesh` listen (no hq-agent, no user-data) |
| `apply.sh` | upgrade this HQ tree + isolated bin |
| `work-mesh doctor` | audit local projects vs mesh, warm cache; `--apply` paced repair |

## Cache

Hot window only (`~/.hq/work-mesh/cache/`). Local sessions should read it for project knowledge. Not Slack-sized history.

## Promote later

When dogfood is over, move this pack into `core/packages/` in hq-core (or fold the helper into `core/scripts/work-mesh.*` and drop the pack). Until then, install with:

```bash
hq install ./packages/source/hq-pack-work-mesh --allow-hooks
bash core/packages/hq-pack-work-mesh/scripts/apply.sh
```
