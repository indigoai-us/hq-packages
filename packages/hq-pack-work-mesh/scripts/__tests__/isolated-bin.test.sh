#!/usr/bin/env bash
# Isolated bin must exec work-mesh.mjs (not hq-work-mesh.mjs) and --help must work.
set -euo pipefail
PACK="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HQ_WORK_MESH_SKIP_MQTT=1
mkdir -p "$HOME"

bash "$PACK/scripts/lib/install-isolated-bin.sh"

test -x "$HOME/.hq/work-mesh/bin/work-mesh.sh"
test -f "$HOME/.hq/work-mesh/bin/work-mesh.mjs"
test -f "$HOME/.hq/work-mesh/bin/work-mesh-doctor.mjs"
test -x "$HOME/.hq/work-mesh/bin/genesis.sh"
if grep -q 'hq-work-mesh.mjs' "$HOME/.hq/work-mesh/bin/work-mesh.sh" && \
   ! grep -q 'work-mesh.mjs' "$HOME/.hq/work-mesh/bin/work-mesh.sh"; then
  echo "isolated-bin.test: wrapper only looks for hq-work-mesh.mjs" >&2
  exit 1
fi

out="$("$HOME/.hq/work-mesh/bin/work-mesh.sh" --help)"
echo "$out" | grep -q listen
echo "isolated-bin.test: ok"
