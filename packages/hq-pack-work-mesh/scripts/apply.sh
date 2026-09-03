#!/usr/bin/env bash
# Apply this pack to the current HQ tree (dogfood install / upgrade).
# Safe: does not overwrite hq-agent, user-data, or a newer core helper.
# Does NOT install the legacy isolated ~/.hq/work-mesh/bin listen daemon.
# Presence and spool flush belong to `hq mesh daemon` (hq-cli).
# Idempotently unloads and removes the old LaunchAgent listen service.
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

HOME_DIR="${HOME:-$(eval echo ~)}"
OLD_LISTEN_LABEL="ai.getindigo.hq-work-mesh-listen"
OLD_LISTEN_PLIST="$HOME_DIR/Library/LaunchAgents/${OLD_LISTEN_LABEL}.plist"
OLD_LISTEN_PIDFILE="$HOME_DIR/.hq/work-mesh/listen.pid"

echo "apply: pack=$PACK_ROOT hq=$HQ_ROOT"

# 1. Unload and remove the legacy listen LaunchAgent (idempotent).
unload_old_listen() {
  if command -v launchctl >/dev/null 2>&1; then
    UID_NUM="$(id -u 2>/dev/null || echo 0)"
    DOMAIN="gui/${UID_NUM}"
    launchctl bootout "${DOMAIN}/${OLD_LISTEN_LABEL}" >/dev/null 2>&1 \
      || launchctl unload -w "$OLD_LISTEN_PLIST" >/dev/null 2>&1 \
      || true
    launchctl disable "${DOMAIN}/${OLD_LISTEN_LABEL}" >/dev/null 2>&1 || true
  fi
  if [ -f "$OLD_LISTEN_PLIST" ] || [ -L "$OLD_LISTEN_PLIST" ]; then
    rm -f "$OLD_LISTEN_PLIST"
    echo "apply: removed legacy LaunchAgent $OLD_LISTEN_LABEL"
  else
    echo "apply: no legacy LaunchAgent plist for $OLD_LISTEN_LABEL"
  fi

  # Linux / nohup leftover from install-listen.sh
  if [ -f "$OLD_LISTEN_PIDFILE" ]; then
    old_pid="$(cat "$OLD_LISTEN_PIDFILE" 2>/dev/null || true)"
    if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
      kill "$old_pid" 2>/dev/null || true
    fi
    rm -f "$OLD_LISTEN_PIDFILE"
    echo "apply: cleared legacy listen pidfile"
  fi
}
unload_old_listen

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

# 3. Drop a stale generic genesis.sh link if an older apply wired one.
if [ -L "$HQ_ROOT/core/scripts/genesis.sh" ]; then
  target="$(readlink "$HQ_ROOT/core/scripts/genesis.sh" || true)"
  case "$target" in
    *hq-pack-work-mesh/scripts/genesis.sh)
      rm -f "$HQ_ROOT/core/scripts/genesis.sh"
      echo "apply: removed generic core/scripts/genesis.sh symlink"
      ;;
  esac
fi

# 4. Insert /prd Step 5.6b so cloud-backed project create writes the mesh.
# Local overlay only (.agents / .claude / personal). Never rewrite hq-core.
bash "$SCRIPT_DIR/lib/patch-prd-genesis.sh" "$HQ_ROOT"

echo "apply: done"
echo "  genesis:  bash $SCRIPT_DIR/hq-work-mesh-genesis.sh --company <slug> <project>"
echo "  daemon:   hq mesh daemon install   # replaces legacy listen (LaunchAgent/systemd)"
echo "  verbs:    hq mesh session | hq mesh context | hq mesh daemon"
echo "  note:     isolated ~/.hq/work-mesh/bin listen is no longer installed by this pack"
