#!/usr/bin/env bash
# Copy the work-mesh helper into ~/.hq/work-mesh/bin so /update-hq cannot
# roll listen back to a July core/scripts/work-mesh.sh. Does not start listen,
# does not touch hq-agent or cloud-init user-data.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_SCRIPTS="$(cd "$LIB_DIR/.." && pwd)"
HOME_DIR="${HOME:-$(eval echo ~)}"
ROOT="$HOME_DIR/.hq/work-mesh"
BIN="$ROOT/bin"
RUNTIME="$ROOT/runtime"

mkdir -p "$BIN" "$ROOT/cache" "$ROOT/logs" "$RUNTIME"

cp "$PACK_SCRIPTS/hq-work-mesh.mjs" "$BIN/work-mesh.mjs"
cp "$PACK_SCRIPTS/work-mesh-doctor.mjs" "$BIN/work-mesh-doctor.mjs"
chmod +x "$BIN/work-mesh.mjs"
if [ -f "$PACK_SCRIPTS/genesis.sh" ]; then
  cp "$PACK_SCRIPTS/genesis.sh" "$BIN/genesis.sh"
  chmod +x "$BIN/genesis.sh"
fi

# Dual-name wrapper: isolated copy is work-mesh.mjs; pack/scripts copy is hq-work-mesh.mjs.
cat > "$BIN/work-mesh.sh" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -f "$SCRIPT_DIR/work-mesh.mjs" ]; then
  MJS="$SCRIPT_DIR/work-mesh.mjs"
elif [ -f "$SCRIPT_DIR/hq-work-mesh.mjs" ]; then
  MJS="$SCRIPT_DIR/hq-work-mesh.mjs"
else
  echo "work-mesh: missing helper .mjs in $SCRIPT_DIR" >&2
  exit 1
fi
if [ -d "$ROOT/runtime/node_modules" ]; then
  export NODE_PATH="$ROOT/runtime/node_modules${NODE_PATH:+:$NODE_PATH}"
fi
if [ -z "${HQ_WORK_MESH_MQTT_MODULE:-}" ] && [ -f "$ROOT/runtime/node_modules/mqtt/package.json" ]; then
  export HQ_WORK_MESH_MQTT_MODULE="$ROOT/runtime/node_modules/mqtt"
fi
exec node "$MJS" "$@"
WRAP
chmod +x "$BIN/work-mesh.sh"

if [ "${HQ_WORK_MESH_SKIP_MQTT:-}" != "1" ] && ! node -e "require('mqtt')" 2>/dev/null; then
  if [ ! -d "$RUNTIME/node_modules/mqtt" ]; then
    (cd "$RUNTIME" && npm install --omit=dev mqtt >/dev/null)
  fi
fi
