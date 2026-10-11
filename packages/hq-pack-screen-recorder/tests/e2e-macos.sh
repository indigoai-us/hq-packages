#!/usr/bin/env bash
# macOS end-to-end check: build HQ Recorder from this pack's source, open it for
# a company, confirm it reports awaiting-start without writing a recording,
# stop it, and confirm a second start reuses the build. Opens a real window.
# Not part of the any-OS suite (it needs macOS 26 and Command Line Tools).
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "e2e-macos.sh needs macOS" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$here/../scripts/hq-record-process.sh"

tmp="$(mktemp -d)"
trap 'bash "$R" stop >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
hq="$tmp/hq"
mkdir -p "$hq/companies/acme"
printf 'companies:\n  acme:\n    name: Acme\n' >"$hq/companies/manifest.yaml"
export HQ_ROOT="$hq" HQ_RECORDER_HOME="$tmp/state"
unset HQ_RECORDER_APP HQ_RECORDER_OPEN

field() { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "$1" "$2"; }
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: expected $3, got $2" >&2; exit 1; }; echo "ok: $1"; }

bash "$R" doctor >/dev/null
out="$(bash "$R" start --company acme)"
expect "first start opens the app" "$(field "$out" state)" "awaiting-start"
expect "bound company" "$(field "$out" company)" "acme"
app="$tmp/state/HQ Recorder.app"
codesign --verify "$app"
expect "app is ad-hoc signed" "$(codesign -dv "$app" 2>&1 | sed -n 's/^Signature=//p')" "adhoc"
pid="$(field "$out" pid)"
kill -0 "$pid" && echo "ok: app process $pid is running"
expect "no recording written on open" "$(ls -A "$hq/companies/acme/recordings" | wc -l | tr -d ' ')" "0"

out="$(bash "$R" stop)"
expect "stop closes the app" "$(field "$out" state)" "closed"
sleep 1
if kill -0 "$pid" 2>/dev/null; then echo "FAIL: app still running after stop" >&2; exit 1; fi
echo "ok: app process exited"

before="$(stat -f %m "$app/Contents/MacOS/HQRecorder")"
out="$(bash "$R" start --company acme)"
expect "second start opens again" "$(field "$out" state)" "awaiting-start"
expect "second start reuses the build" "$(stat -f %m "$app/Contents/MacOS/HQRecorder")" "$before"
out="$(bash "$R" stop)"
expect "second stop closes" "$(field "$out" state)" "closed"
echo "e2e-macos: passed"
