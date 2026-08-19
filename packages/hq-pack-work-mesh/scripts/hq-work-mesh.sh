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
