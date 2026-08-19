#!/bin/bash
# Heal the isolated work-mesh helper if it is missing. Kick listen if it is
# already installed (LaunchAgent on macOS, nohup pidfile on Linux).
# Never touches hq-agent.
set -uo pipefail

[ "${HQ_NO_WORK_MESH_BIN_HEAL:-}" = "1" ] && exit 0
if [ -f "${HOME:-}/Library/LaunchAgents/ai.getindigo.hq-work-mesh-listen.plist" ]; then
  launchctl kickstart -k "gui/$(id -u)/ai.getindigo.hq-work-mesh-listen" >/dev/null 2>&1 || true
elif [ "$(uname -s)" != Darwin ] && [ -f "${HOME:-}/.hq/work-mesh/bin/work-mesh.mjs" ]; then
  HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  INSTALL="$HOOK_DIR/../../scripts/install-listen.sh"
  if [ -f "$INSTALL" ]; then
    bash "$INSTALL" >/dev/null 2>&1 || true
  fi
fi
[ -x "${HOME:-}/.hq/work-mesh/bin/work-mesh.sh" ] && [ -f "${HOME:-}/.hq/work-mesh/bin/work-mesh.mjs" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
LIB="$PACK_ROOT/scripts/lib/install-isolated-bin.sh"
if [ -f "$LIB" ]; then
  bash "$LIB" >/dev/null 2>&1 || true
fi
exit 0
