#!/usr/bin/env bash
# hq-record-process — launch and control the local HQ Recorder helper for /record-process.
#
# The helper app is built on this Mac from the Swift sources shipped in this
# pack (app/Sources) using Apple's Command Line Tools, then ad-hoc signed.
# Nothing is downloaded and no Apple developer account is needed.
#
# Subcommands (all print one JSON object on stdout):
#   doctor                      check this Mac can build and run the helper
#   build [--force]             build the helper if missing or out of date
#   start [--company <slug>]    open the helper bound to a company's recordings folder
#   status                      report the helper's current state
#   stop                        ask the helper to stop and wait for it to close
#
# Environment overrides (used by tests):
#   HQ_ROOT            HQ root (default: nearest parent with companies/manifest.yaml)
#   HQ_RECORDER_HOME   state dir (default: ~/Library/Application Support/HQ Recorder)
#   HQ_RECORDER_APP    helper app path (default: $HQ_RECORDER_HOME/HQ Recorder.app)
#   HQ_RECORDER_OPEN   command used to launch the app (default: open -n)
set -euo pipefail

script_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}")"
pack_dir="$(cd "$(dirname "$script_path")/.." && pwd)"
app_src="$pack_dir/app/Sources"
state_dir="${HQ_RECORDER_HOME:-$HOME/Library/Application Support/HQ Recorder}"
app_path="${HQ_RECORDER_APP:-$state_dir/HQ Recorder.app}"
control_dir="$state_dir/active"
status_file="$control_dir/status.json"
stamp_file="$state_dir/build.stamp"

# json key value [key value ...] — values are emitted as strings, except
# true/false/null and integers, which are emitted raw.
json() {
  python3 -I -c '
import json, re, sys
a = sys.argv[1:]
out = {}
for k, v in zip(a[::2], a[1::2]):
    if v in ("true", "false"): out[k] = v == "true"
    elif v == "null": out[k] = None
    elif re.fullmatch(r"-?\d+", v): out[k] = int(v)
    else: out[k] = v
print(json.dumps(out))' "$@"
}

fail() { json ok false error "$1" message "$2"; exit 1; }

find_hq_root() {
  if [ -n "${HQ_ROOT:-}" ]; then printf '%s\n' "$HQ_ROOT"; return; fi
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -f "$d/companies/manifest.yaml" ] && { printf '%s\n' "$d"; return; }
    d="$(dirname "$d")"
  done
  return 1
}

sources_hash() {
  (cd "$app_src" && ls *.swift | LC_ALL=C sort | xargs cat) | shasum -a 256 | cut -d' ' -f1
}

doctor_checks() {
  # Prints "name<TAB>ok<TAB>detail" lines.
  local os arch ver swift_ok sdk_ok
  os="$(uname -s)"; arch="$(uname -m)"
  printf 'macos\t%s\t%s\n' "$([ "$os" = Darwin ] && echo true || echo false)" "$os"
  printf 'apple_silicon\t%s\t%s\n' "$([ "$arch" = arm64 ] && echo true || echo false)" "$arch"
  if [ "$os" = Darwin ]; then
    ver="$(sw_vers -productVersion)"
    printf 'macos_26_or_later\t%s\t%s\n' "$([ "${ver%%.*}" -ge 26 ] && echo true || echo false)" "$ver"
    if xcrun --sdk macosx --find swiftc >/dev/null 2>&1; then swift_ok=true; else swift_ok=false; fi
    printf 'command_line_tools\t%s\t%s\n' "$swift_ok" "$(xcode-select -p 2>/dev/null || echo missing)"
    sdk_ok=false
    if [ "$swift_ok" = true ] && [ -d "$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)/System/Library/Frameworks/ScreenCaptureKit.framework" ]; then sdk_ok=true; fi
    printf 'macos_sdk\t%s\t%s\n' "$sdk_ok" "$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo missing)"
  fi
}

cmd_doctor() {
  local args=(ok true) all=true name ok detail
  while IFS=$'\t' read -r name ok detail; do
    args+=("$name" "$ok" "${name}_detail" "$detail")
    [ "$ok" = true ] || all=false
  done < <(doctor_checks)
  args[1]="$all"
  [ "$all" = true ] || args+=(fix "Run: xcode-select --install   (installs Apple's free Command Line Tools). The recorder needs an Apple Silicon Mac on macOS 26 or later.")
  json "${args[@]}"
  [ "$all" = true ]
}

build_app() {
  local force="${1:-false}" want
  want="$(sources_hash)"
  if [ "$force" != true ] && [ -x "$app_path/Contents/MacOS/HQRecorder" ] && [ "$(cat "$stamp_file" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  if ! cmd_doctor >/dev/null; then
    cmd_doctor; exit 1
  fi
  mkdir -p "$state_dir"
  local tmp="$state_dir/.build-$$"
  rm -rf "$tmp"; mkdir -p "$tmp/HQ Recorder.app/Contents/MacOS"
  local log="$state_dir/build.log"
  if ! xcrun --sdk macosx swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macos26.0 \
      "$app_src"/*.swift -o "$tmp/HQ Recorder.app/Contents/MacOS/HQRecorder" >"$log" 2>&1; then
    rm -rf "$tmp"
    fail build-failed "The recorder app did not compile. Details: $log"
  fi
  cp "$pack_dir/app/Info.plist" "$tmp/HQ Recorder.app/Contents/Info.plist"
  codesign --force --sign - --options runtime "$tmp/HQ Recorder.app" >>"$log" 2>&1 \
    || { rm -rf "$tmp"; fail sign-failed "Signing the locally built app failed. Details: $log"; }
  rm -rf "$app_path"
  mkdir -p "$(dirname "$app_path")"
  mv "$tmp/HQ Recorder.app" "$app_path"
  rmdir "$tmp"
  printf '%s\n' "$want" >"$stamp_file"
  built=true
}

cmd_build() {
  local force=false
  [ "${1:-}" = --force ] && force=true
  built=false
  build_app "$force"
  json ok true app "$app_path" built "$built"
}

# Prints the helper's state, mapping a vanished process to "lost".
current_state() {
  [ -f "$status_file" ] || { echo none; return; }
  local state pid
  state="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$status_file")"
  pid="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$status_file")"
  case "$state" in
    closed|saved|failed) echo "$state" ;;
    *) if kill -0 "$pid" 2>/dev/null; then echo "$state"; else echo lost; fi ;;
  esac
}

cmd_status() {
  local state
  state="$(current_state)"
  if [ "$state" = none ]; then json ok true state none; return; fi
  python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1]))
s["ok"] = True
s["state"] = sys.argv[2]
print(json.dumps(s))' "$status_file" "$state"
}

cmd_start() {
  local company=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --company) company="${2:-}"; shift 2 ;;
      *) fail bad-argument "Unknown argument: $1" ;;
    esac
  done
  local root
  root="$(find_hq_root)" || fail no-hq "Run /record-process from inside an HQ folder."
  if [ -z "$company" ] && [ -f "$root/core/scripts/hq-session.sh" ]; then
    company="$(bash "$root/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
  fi
  if [ -z "$company" ] || [ "$company" = personal ]; then
    fail no-company "This session isn't working in a company. Pick the company first, then run /record-process again."
  fi
  [[ "$company" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail bad-company "That company name isn't valid: $company"
  grep -Eq "^  ${company}:" "$root/companies/manifest.yaml" && [ -d "$root/companies/$company" ] \
    || fail unknown-company "There's no company called $company in this HQ."

  local state
  state="$(current_state)"
  case "$state" in
    awaiting-start|recording|finalizing)
      fail already-open "The recorder is already open (state: $state). Stop it before starting another." ;;
  esac

  local destination="$root/companies/$company/recordings"
  mkdir -p "$destination" 2>/dev/null || fail destination-unwritable "Can't create $destination."
  [ -w "$destination" ] || fail destination-unwritable "Can't write to $destination."

  built=false
  if [ -z "${HQ_RECORDER_APP:-}" ] || [ ! -e "$app_path" ]; then build_app; fi

  rm -rf "$control_dir"; mkdir -p "$control_dir"
  local opener="${HQ_RECORDER_OPEN:-open -n}"
  # shellcheck disable=SC2086
  $opener "$app_path" --args --hq-control "$control_dir" --company "$company" --destination "$destination" >/dev/null \
    || fail launch-failed "macOS could not open the recorder app."

  local i
  for i in $(seq 1 60); do
    [ -f "$status_file" ] && break
    sleep 0.25
  done
  [ -f "$status_file" ] || fail no-status "The recorder opened but didn't report back within 15 seconds."
  cmd_status
}

cmd_stop() {
  local state
  state="$(current_state)"
  case "$state" in
    none|closed|saved|failed|lost) cmd_status; return ;;
  esac
  : >"$control_dir/stop.request"
  local i
  for i in $(seq 1 80); do
    state="$(current_state)"
    case "$state" in closed|saved|failed|lost) break ;; esac
    sleep 0.25
  done
  cmd_status
}

case "${1:-}" in
  doctor) shift; cmd_doctor "$@" ;;
  build) shift; cmd_build "$@" ;;
  start) shift; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  *) echo "usage: hq-record-process.sh {doctor|build [--force]|start [--company <slug>]|status|stop}" >&2; exit 2 ;;
esac
