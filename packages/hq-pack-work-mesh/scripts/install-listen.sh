#!/usr/bin/env bash
# Isolated work-mesh listen — always-on cache writer for this machine.
# Never overwrites hq-agent/core or cloud-init user-data.
#
# V2 desktop (hq-work-desktop) is a cache READER. It must not block listen.
# Only skip a second start when listen itself is already running.
#
# MQTT here is a Node *client* to AWS IoT Core. Do not install a broker
# (mosquitto, etc.). install-isolated-bin.sh npm-installs the `mqtt` package
# into ~/.hq/work-mesh/runtime. Deacon's box is this same path: a detached
# `node ~/.hq/work-mesh/bin/work-mesh.mjs listen` as ec2-user.
#
# Darwin → LaunchAgent. Linux / other → nohup + pidfile (job watchdogs
# kill an in-session listen at ~300s idle / 900s absolute).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME:-$(eval echo ~)}"
ROOT="$HOME_DIR/.hq/work-mesh"
BIN="$ROOT/bin"
LOG="$ROOT/logs/listen.log"
CACHE="$ROOT/live-cache.json"
RUNTIME="$ROOT/runtime"
PIDFILE="$ROOT/listen.pid"
LABEL="ai.getindigo.hq-work-mesh-listen"
PLIST="$HOME_DIR/Library/LaunchAgents/${LABEL}.plist"

bash "$SCRIPT_DIR/lib/install-isolated-bin.sh"
mkdir -p "$ROOT/logs"

listen_running() {
  ps -u "$(id -un)" -o pid=,command= 2>/dev/null \
    | grep -v grep \
    | grep -Eq 'work-mesh\.mjs listen|hq-work-mesh\.mjs listen'
}

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  for candidate in /usr/bin/node /usr/local/bin/node /opt/homebrew/bin/node; do
    if [ -x "$candidate" ]; then
      NODE_BIN="$candidate"
      break
    fi
  done
fi
if [ -z "$NODE_BIN" ]; then
  echo "install-listen: node not found on PATH" >&2
  exit 1
fi

NODE_PATH_VAL=""
if [ -d "$RUNTIME/node_modules" ]; then
  NODE_PATH_VAL="$RUNTIME/node_modules"
fi
MQTT_MOD="${HQ_WORK_MESH_MQTT_MODULE:-$RUNTIME/node_modules/mqtt}"

export_listen_env() {
  export HOME="$HOME_DIR"
  export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"
  if [ -n "$NODE_PATH_VAL" ]; then
    export NODE_PATH="$NODE_PATH_VAL${NODE_PATH:+:$NODE_PATH}"
  fi
  if [ -f "$MQTT_MOD/package.json" ] || [ -d "$MQTT_MOD" ]; then
    export HQ_WORK_MESH_MQTT_MODULE="$MQTT_MOD"
  fi
}

start_launchd() {
  mkdir -p "$HOME_DIR/Library/LaunchAgents"
  cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${BIN}/work-mesh.mjs</string>
    <string>listen</string>
    <string>--cache-file</string>
    <string>${CACHE}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${ROOT}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG}</string>
  <key>StandardErrorPath</key>
  <string>${LOG}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME_DIR}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>NODE_PATH</key>
    <string>${NODE_PATH_VAL}</string>
    <key>HQ_WORK_MESH_MQTT_MODULE</key>
    <string>${MQTT_MOD}</string>
  </dict>
</dict>
</plist>
PLIST

  UID_NUM="$(id -u)"
  DOMAIN="gui/${UID_NUM}"
  if ! launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    launchctl bootstrap "${DOMAIN}" "$PLIST" >/dev/null 2>&1 \
      || launchctl load -w "$PLIST" >/dev/null 2>&1 \
      || true
  fi
  launchctl enable "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
  launchctl kickstart -k "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true

  sleep 1
  if listen_running; then
    echo "install-listen: running (launchd ${LABEL}) log $LOG cache $ROOT/cache"
  else
    echo "install-listen: launchd loaded but process not visible yet — see $LOG" >&2
  fi
}

start_nohup() {
  if listen_running; then
    echo "install-listen: already running (nohup) log $LOG cache $ROOT/cache"
    return 0
  fi
  if [ -f "$PIDFILE" ]; then
    old="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${old:-}" ] && kill -0 "$old" 2>/dev/null; then
      echo "install-listen: already running (pid $old) log $LOG cache $ROOT/cache"
      return 0
    fi
    rm -f "$PIDFILE"
  fi

  export_listen_env
  cd "$ROOT"
  nohup "$NODE_BIN" "$BIN/work-mesh.mjs" listen --cache-file "$CACHE" \
    >>"$LOG" 2>&1 </dev/null &
  echo $! >"$PIDFILE"
  disown $! 2>/dev/null || true

  sleep 1
  if listen_running; then
    echo "install-listen: running (nohup pid $(cat "$PIDFILE" 2>/dev/null || echo '?')) log $LOG cache $ROOT/cache"
  else
    echo "install-listen: nohup started but process not visible yet — see $LOG" >&2
  fi
}

UNAME="$(uname -s)"
if [ "$UNAME" = Darwin ]; then
  start_launchd
else
  start_nohup
fi

echo "install-listen: did not touch hq-agent or user-data"
echo "install-listen: mqtt is the npm client under $RUNTIME/node_modules/mqtt — not a broker"
