#!/usr/bin/env bash
# Real customer build plus a headless runtime smoke check. No GUI or permissions.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(uname -s)" = Darwin && -d /Library/Developer/CommandLineTools ]] || {
  echo "This check requires macOS and Command Line Tools" >&2; exit 2;
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" HQ_RECORDER_HOME="$tmp/state" HQ_RECORDER_LEGACY_HOME="$tmp/legacy"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
unset HQ_RECORDER_APP HQ_RECORDER_COMPILE
mkdir -p "$HOME" "$tmp/bin"
# Restrict this fixture to the real CLT toolchain. Production fallback remains
# available, but must not mask a broken CLT build on a developer with Xcode.
cat >"$tmp/bin/xcode-select" <<'SH'
#!/bin/sh
printf '%s\n' /Library/Developer/CommandLineTools
SH
chmod +x "$tmp/bin/xcode-select"
export PATH="$tmp/bin:$PATH"
export HQ_RECORDER_CLT_DIR=/Library/Developer/CommandLineTools
export HQ_RECORDER_XCODE_DIR="$tmp/no-xcode"
doctor_json="$(bash "$here/../scripts/hq-record-process.sh" doctor)"
printf '%s\n' "$doctor_json"
python3 -c 'import json,sys; j=json.load(sys.stdin); assert j["ok"] and j["compile_probe"] and j["command_line_tools_detail"] == "/Library/Developer/CommandLineTools"' <<<"$doctor_json"
xcrun --show-sdk-version
swift --version
bash "$here/clt-state.test.sh"
if ! bash "$here/../scripts/hq-record-process.sh" build --force; then
  cat "$HQ_RECORDER_HOME/build.log" >&2
  exit 1
fi
# Prove the signed binary loads and reaches the command handler, without opening
# a window, touching real recordings or requesting screen/camera/mic permission.
code=0
"$HQ_RECORDER_HOME/HQ Capture.app/Contents/MacOS/LocalScreenRecorder" \
  --describe "$tmp/outside.hqrec" --json >"$tmp/run.log" 2>&1 || code=$?
cat "$tmp/run.log"
[[ "$code" = 2 ]]
grep -q 'The package must be inside companies/<company>/recordings.' "$tmp/run.log"
echo "ok: CLT build, bundle validation and headless runtime"
