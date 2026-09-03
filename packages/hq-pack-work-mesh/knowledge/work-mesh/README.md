# Work mesh (pack)

Dogfood layer for genesis and Board helpers. **0.2.0** retired the pack-owned
`listen` / `watch` cache daemon in favor of **`hq mesh daemon`** (hq-cli).

## Pieces

| Piece | Role |
|---|---|
| `hq-work-mesh.sh` / `.mjs` | check / start / progress / story / doctor (no listen/watch) |
| `genesis.sh` | thread + ensure-project + PROJECT_VIEW PUT |
| `apply.sh` | wire pack + unload legacy `ai.getindigo.hq-work-mesh-listen` |
| `hq mesh daemon` (hq-cli) | presence, spool flush, MQTT — install separately |

## Promote later

Fold genesis into hq-core. The resident process stays in hq-cli forever.
