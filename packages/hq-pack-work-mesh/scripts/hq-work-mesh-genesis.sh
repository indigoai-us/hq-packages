#!/usr/bin/env bash
# Namespaced entry so scan-packages does not claim core/scripts/genesis.sh.
# Resolve through the host symlink (core/scripts/hq-work-mesh-genesis.sh).
set -euo pipefail
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  LINK="$(readlink "$SOURCE")"
  case "$LINK" in
    /*) SOURCE="$LINK" ;;
    *) SOURCE="$DIR/$LINK" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
exec bash "$SCRIPT_DIR/genesis.sh" "$@"
