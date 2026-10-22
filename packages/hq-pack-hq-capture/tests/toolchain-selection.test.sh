#!/usr/bin/env bash
# Integration of the CLT-compatible wrapper/probe with current developer-tool fallback.
# All developer tools and host metadata are synthetic; no compile, GUI or install occurs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
cat >"$tmp/bin/uname" <<'SH'
#!/bin/sh
[ "${1:-}" = -m ] && echo arm64 || echo Darwin
SH
cat >"$tmp/bin/sw_vers" <<'SH'
#!/bin/sh
echo "${TEST_MACOS_VERSION:-26.1}"
SH
cat >"$tmp/bin/xcode-select" <<'SH'
#!/bin/sh
echo "$TEST_SELECTED_DEV"
SH
cat >"$tmp/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -eu
d="${DEVELOPER_DIR:?}"
case "$*" in
  '--sdk macosx --find swiftc') [ -f "$d/swiftc" ] && echo "$d/swiftc" ;;
  '--sdk macosx --show-sdk-path') echo "$d/sdk" ;;
  '--sdk macosx --show-sdk-version') cat "$d/sdk-version" ;;
  '--sdk macosx swiftc --version') echo 'Apple Swift version 6.4 (synthetic)' ;;
  '--sdk macosx swiftc '*'-typecheck '*)
    printf '%s|%s\n' "$d" "$*" >>"$TEST_COMPILER_CALLS"
    [ "$(cat "$d/mode")" = pass ] || { echo 'synthetic compiler rejection' >&2; exit 1; }
    for arg in "$@"; do source="$arg"; done
    for expected in '@CaptureState' '@Observable' 'Binding(' 'glassEffect'; do
      grep -Fq "$expected" "$source" || { echo "probe omitted $expected" >&2; exit 1; }
    done ;;
  *) echo 'unexpected synthetic xcrun invocation' >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/bin"/*
pass=0
assert_json() {
  python3 -I -c 'import json,sys; j=json.loads(sys.argv[1]); assert eval(sys.argv[2]), j' "$1" "$2"
  pass=$((pass + 1))
}
make_dev() {
  mkdir -p "$1/sdk/System/Library/Frameworks/ScreenCaptureKit.framework"
  rm -f "$1/swiftc"; printf 'synthetic compiler\n' >"$1/swiftc"
  printf '%s\n' "$2" >"$1/sdk-version"
  printf '%s\n' "$3" >"$1/mode"
}
for pack in hq-pack-hq-capture hq-pack-screen-recorder; do
  script="$root/packages/$pack/scripts/hq-record-process.sh"
  devs="$tmp/$pack"; clt="$devs/CLT"; xcode="$devs/Xcode"; state="$devs/state"
  make_dev "$clt" 27.0 pass; make_dev "$xcode" 27.0 pass
  export TEST_SELECTED_DEV="$clt" TEST_COMPILER_CALLS="$devs/compiler-calls" TEST_MACOS_VERSION=26.1
  : >"$TEST_COMPILER_CALLS"
  doctor() {
    HOME="$tmp/home" HQ_RECORDER_HOME="$state" \
      HQ_RECORDER_CLT_DIR="$clt" HQ_RECORDER_XCODE_DIR="$xcode" \
      DEVELOPER_DIR="$clt" PATH="$tmp/bin:$PATH" /bin/bash "$script" doctor
  }
  doc="$(doctor)"
  assert_json "$doc" 'j["ok"] and j["compile_probe"] and j["command_line_tools_detail"].endswith("/CLT")'
  doc="$(doctor)"
  assert_json "$doc" 'j["ok"] and j["compile_probe"]'
  [ "$(wc -l <"$TEST_COMPILER_CALLS" | tr -d ' ')" = 1 ]; pass=$((pass + 1))
  grep -Fq -- '-parse-as-library -swift-version 6 -O -target arm64-apple-macos26.0 -framework AVKit' "$TEST_COMPILER_CALLS"; pass=$((pass + 1))

  # An actual capability refusal chooses the existing Xcode candidate; no SDK downgrade.
  rm -rf "$state"; make_dev "$clt" 27.0 fail
  doc="$(doctor)"
  assert_json "$doc" 'j["ok"] and j["compile_probe"] and j["command_line_tools_detail"].endswith("/Xcode")'
  rm -rf "$state" "$xcode"
  doc="$(doctor || true)"
  assert_json "$doc" 'not j["ok"] and not j["compile_probe"] and "hq install hq-capture" in j["fix"]'

  # SDK floor and host OS failures must not typecheck or recommend a tools-only OS fix.
  rm -rf "$state"; make_dev "$clt" 15.5 pass; : >"$TEST_COMPILER_CALLS"
  doc="$(doctor || true)"
  assert_json "$doc" 'not j["ok"] and not j["macos_sdk"] and "macOS 26 SDK or newer" in j["fix"]'
  [ ! -s "$TEST_COMPILER_CALLS" ]; pass=$((pass + 1))
  make_dev "$clt" 27.0 pass; TEST_MACOS_VERSION=15.6.1
  doc="$(doctor || true)"
  assert_json "$doc" 'not j["ok"] and not j["macos_26_or_later"] and j["fix"].startswith("Upgrade this Mac to macOS 26")'
  [ ! -s "$TEST_COMPILER_CALLS" ]; pass=$((pass + 1))
done
printf 'toolchain selection integration: %s checks passed\n' "$pass"
