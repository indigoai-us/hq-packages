#!/usr/bin/env bash
# macOS end-to-end check: build HQ Capture from this pack's source with the Command Line
# Tools, confirm the bundle (name, icon, signature, entitlements), open it for a company,
# confirm it reports awaiting-start without writing a recording, stop it, confirm a second
# start reuses the build, and confirm the 0.1.0 app is removed after the build. Opens a real
# window. Not part of the any-OS suite (it needs macOS 26 and Command Line Tools).
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "e2e-macos.sh needs macOS" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$here/../scripts/hq-record-process.sh"

tmp="$(mktemp -d)"
trap 'bash "$R" stop >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
hq="$tmp/hq"
mkdir -p "$hq/companies/acme/recordings" "$hq/core/scripts" "$tmp/legacy/LocalScreenRecorder.app/Contents"
printf 'companies:\n  acme:\n    name: Acme\n' >"$hq/companies/manifest.yaml"
printf '#!/usr/bin/env bash\n[ "$1 $2" = "get company_slug" ] && echo acme\n' >"$hq/core/scripts/hq-session.sh"
export HQ_ROOT="$hq" HQ_RECORDER_HOME="$tmp/state" HQ_RECORDER_LEGACY_HOME="$tmp/legacy"
unset HQ_RECORDER_APP HQ_RECORDER_OPEN HQ_RECORDER_COMPILE

field() { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "$1" "$2"; }
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: expected $3, got $2" >&2; exit 1; }; echo "ok: $1"; }

bash "$R" doctor >/dev/null
out="$(bash "$R" start --company acme)"
expect "first start opens the app" "$(field "$out" state)" "awaiting-start"
expect "bound company" "$(field "$out" company)" "acme"
app="$tmp/state/HQ Capture.app"
exe="$app/Contents/MacOS/LocalScreenRecorder"
[ -x "$exe" ] && echo "ok: HQ Capture.app has the LocalScreenRecorder executable" \
  || { echo "FAIL: HQ Capture.app has no LocalScreenRecorder executable" >&2; exit 1; }
expect "bundle name" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist")" "HQ Capture"
expect "bundle id" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" "com.indigo.local-screen-recorder"
[ -f "$app/Contents/Resources/AppIcon.icns" ] && echo "ok: icon is in the bundle" \
  || { echo "FAIL: the icon is missing from the bundle" >&2; exit 1; }
otool -L "$exe" | grep -q AVKit.framework && echo "ok: links AVKit" \
  || { echo "FAIL: the executable does not link AVKit" >&2; exit 1; }
codesign --verify --strict "$app"
expect "app is ad-hoc signed" "$(codesign -dv "$app" 2>&1 | sed -n 's/^Signature=//p')" "adhoc"
ents="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
grep -q com.apple.security.device.camera <<<"$ents" && grep -q com.apple.security.device.audio-input <<<"$ents" \
  && echo "ok: camera and microphone entitlements are signed in" \
  || { echo "FAIL: the camera or microphone entitlement is not signed in" >&2; exit 1; }
[ ! -e "$tmp/legacy/LocalScreenRecorder.app" ] && echo "ok: the 0.1.0 app was removed after the build" \
  || { echo "FAIL: the 0.1.0 app was not removed after the build" >&2; exit 1; }
pid="$(field "$out" pid)"
kill -0 "$pid" && echo "ok: app process $pid is running" \
  || { echo "FAIL: app process $pid is not running" >&2; exit 1; }
expect "no recording written on open" "$(ls -A "$hq/companies/acme/recordings" | wc -l | tr -d ' ')" "0"

out="$(bash "$R" stop)"
expect "stop closes the app" "$(field "$out" state)" "closed"
sleep 1
if kill -0 "$pid" 2>/dev/null; then echo "FAIL: app still running after stop" >&2; exit 1; fi
echo "ok: app process exited"

# The headless agent commands run from the same build and stay inside the company.
set +e
bash "$R" run describe "$hq/companies/acme/recordings/missing.hqrec" >/dev/null 2>&1; code=$?
set -e
expect "run refuses a missing package" "$code" "3"

before="$(stat -f %m "$exe")"
out="$(bash "$R" start)"
expect "second start opens again" "$(field "$out" state)" "awaiting-start"
expect "second start reuses the build" "$(stat -f %m "$exe")" "$before"
out="$(bash "$R" stop)"
expect "second stop closes" "$(field "$out" state)" "closed"
echo "e2e-macos: passed"
