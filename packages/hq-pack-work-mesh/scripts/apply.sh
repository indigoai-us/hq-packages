#!/usr/bin/env bash
# Apply this pack to the current HQ tree (dogfood install / upgrade).
# Safe: does not overwrite hq-agent, user-data, or a newer core helper.
# Does not start listen — desktop MQTT may already own the cache writer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HQ_ROOT="${HQ_ROOT:-}"
if [ -z "$HQ_ROOT" ]; then
  if [ -d "$PACK_ROOT/../../../companies" ]; then
    HQ_ROOT="$(cd "$PACK_ROOT/../../.." && pwd)"
  else
    HQ_ROOT="$(pwd)"
  fi
fi

echo "apply: pack=$PACK_ROOT hq=$HQ_ROOT"

# 1. Isolated machine helper (always — this is the upgrade that survives /update-hq).
bash "$SCRIPT_DIR/lib/install-isolated-bin.sh"
echo "apply: isolated helper $HOME/.hq/work-mesh/bin/work-mesh.sh"

# 2. Wire pack into core/packages so scan-packages can symlink (no clobber).
DEST="$HQ_ROOT/core/packages/hq-pack-work-mesh"
if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
  echo "apply: $DEST already exists as a directory — leaving it"
elif [ ! -e "$DEST" ]; then
  mkdir -p "$(dirname "$DEST")"
  ln -s "$PACK_ROOT" "$DEST"
  echo "apply: linked $DEST -> $PACK_ROOT"
fi
if [ -x "$HQ_ROOT/core/scripts/scan-packages.sh" ]; then
  (cd "$HQ_ROOT" && bash core/scripts/scan-packages.sh) || true
fi

# 3. Do not replace an existing core/scripts/work-mesh.sh (July copies, /update-hq).
if [ -f "$HQ_ROOT/core/scripts/work-mesh.mjs" ] && ! grep -q classifyCacheWake "$HQ_ROOT/core/scripts/work-mesh.mjs"; then
  echo "apply: existing core/scripts/work-mesh.mjs has no listen cache — use ~/.hq/work-mesh/bin or core/scripts/hq-work-mesh.sh"
fi

# 4. Drop a stale generic genesis.sh link if an older apply wired one.
if [ -L "$HQ_ROOT/core/scripts/genesis.sh" ]; then
  target="$(readlink "$HQ_ROOT/core/scripts/genesis.sh" || true)"
  case "$target" in
    *hq-pack-work-mesh/scripts/genesis.sh)
      rm -f "$HQ_ROOT/core/scripts/genesis.sh"
      echo "apply: removed generic core/scripts/genesis.sh symlink"
      ;;
  esac
fi

# 5. Insert /prd Step 5.6b so cloud-backed project create writes the mesh.
# Local overlay only (.agents / .claude / personal). Never rewrite hq-core.
bash "$SCRIPT_DIR/lib/patch-prd-genesis.sh" "$HQ_ROOT"

echo "apply: done"
echo "  genesis:  bash $SCRIPT_DIR/hq-work-mesh-genesis.sh --company <slug> <project>"
echo "  listen:   bash $SCRIPT_DIR/install-listen.sh   # always-on cache writer (LaunchAgent / Linux nohup)"
echo "  verbs:    bash $HOME/.hq/work-mesh/bin/work-mesh.sh --help"
echo "  cache:    ~/.hq/work-mesh/cache/"
