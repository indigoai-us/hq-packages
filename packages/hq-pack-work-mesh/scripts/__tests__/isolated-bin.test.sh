#!/usr/bin/env bash
# Legacy isolated-bin helper may still be copied manually, but --help must not
# advertise listen/watch (removed in 0.2.0). apply.sh no longer installs it.
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
echo "$out" | grep -q doctor
echo "$out" | grep -q 'hq mesh daemon'
! echo "$out" | grep -E '^  listen ' >/dev/null
! echo "$out" | grep -E '^  watch ' >/dev/null

set +e
err="$("$HOME/.hq/work-mesh/bin/work-mesh.sh" listen 2>&1)"
code=$?
set -e
test "$code" -eq 2
echo "$err" | grep -q 'hq mesh daemon'

echo "isolated-bin.test: ok"
