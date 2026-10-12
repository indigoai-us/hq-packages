#!/usr/bin/env bash
# hq-record-process — launch and control HQ Capture for /record-process.
#
# HQ Capture is built on this Mac from the Swift sources shipped in this pack
# (app/Sources) with Apple's Command Line Tools, then ad-hoc signed. Nothing is
# downloaded and no Apple developer account is needed. The build is redone when
# app/SOURCE or any shipped source, plist, entitlement or icon changes, so a
# pack update rebuilds the app.
#
# Subcommands (each prints JSON on stdout):
#   doctor                        check this Mac can build and run the app
#   build [--force]               build the app if missing or out of date
#   start [--company <slug>]      open HQ Capture bound to a company's recordings folder
#   status                        print status.json with the live state; after a save it adds
#                                 mediaIssues from the package and keeps the app's issue note
#   wait [--timeout <seconds>]    block until the state is saved, failed, closed or lost,
#                                 printing one line per change (with issue when the app sets
#                                 one) and the full status last; exit 3 when still open at timeout
#   stop                          write stop.request and wait for the app to close
#   run <mode> <package> [args]   run an agent command headless on a saved recording
#   resume <prompt>               check a pasted resume prompt and print its package
#
# run modes: describe, transcribe, edit, export-video, frame, review-sop, approve-sop,
# list-frames, draft-sop, export-sop, extract-screen-evidence, sync-package. run prints the app's own output and exits with
# its code (0 done, 1 refused, 2 usage or error, 130 cancelled). A launcher refusal
# prints {"ok": false, ...} and exits 3 for run and resume, 1 for the other subcommands.
#
# Every subcommand that touches a company uses the session's bound company and refuses
# a company or a package outside it.
#
# Environment overrides (used by tests):
#   HQ_ROOT              HQ root (default: nearest parent with companies/manifest.yaml)
#   HQ_RECORDER_HOME     state dir (default: ~/Library/Application Support/HQ Capture)
#   HQ_RECORDER_APP      app path (default: $HQ_RECORDER_HOME/HQ Capture.app)
#   HQ_RECORDER_OPEN     command used to launch the app (default: open -n)
#   HQ_RECORDER_LEGACY_HOME  0.1.0 state dir whose old app is removed after a build
#                        (default: ~/Library/Application Support/HQ Recorder)
#   HQ_RECORDER_COMPILE  command run with the unsigned app path instead of the
#                        compile, sign and check steps (tests only)
set -euo pipefail

script_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}")"
pack_dir="$(cd "$(dirname "$script_path")/.." && pwd)"
app_src="$pack_dir/app/Sources"
state_dir="${HQ_RECORDER_HOME:-$HOME/Library/Application Support/HQ Capture}"
app_path="${HQ_RECORDER_APP:-$state_dir/HQ Capture.app}"
executable="LocalScreenRecorder"
control_dir="$state_dir/active"
status_file="$control_dir/status.json"
stamp_file="$state_dir/build.stamp"
refusal_code=1

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

fail() { json ok false error "$1" message "$2"; exit "$refusal_code"; }

find_hq_root() {
  if [ -n "${HQ_ROOT:-}" ]; then printf '%s\n' "$HQ_ROOT"; return; fi
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -f "$d/companies/manifest.yaml" ] && { printf '%s\n' "$d"; return; }
    d="$(dirname "$d")"
  done
  return 1
}

realpath_of() { python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"; }

# Resolves and checks the company. Sets root, company and destination.
# An explicit --company must match the session's bound company when one is bound.
resolve_company() {
  local requested="${1:-}" bound=""
  root="$(find_hq_root)" || fail no-hq "Run /record-process from inside an HQ folder."
  root="$(realpath_of "$root")"
  if [ -f "$root/core/scripts/hq-session.sh" ]; then
    bound="$(bash "$root/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
  fi
  [ "$bound" = personal ] && bound=""
  if [ -n "$requested" ] && [ -n "$bound" ] && [ "$requested" != "$bound" ]; then
    fail company-mismatch "This session is bound to $bound, not $requested. HQ Capture only works in the bound company."
  fi
  company="${requested:-$bound}"
  if [ -z "$company" ] || [ "$company" = personal ]; then
    fail no-company "This session isn't working in a company. Pick the company first, then run /record-process again."
  fi
  [[ "$company" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail bad-company "That company name isn't valid: $company"
  grep -Eq "^  ${company}:" "$root/companies/manifest.yaml" && [ -d "$root/companies/$company" ] \
    || fail unknown-company "There's no company called $company in this HQ."
  destination="$root/companies/$company/recordings"
}

# Checks that a package is a .hqrec folder directly inside the bound company's recordings
# folder, after resolving symlinks. Sets package to the resolved path.
resolve_package() {
  local given="$1" real recordings
  [ -n "$given" ] || fail no-package "Give the path to a saved .hqrec recording."
  case "$given" in /*) ;; *) given="$PWD/$given" ;; esac
  real="$(realpath_of "$given")"
  recordings="$(realpath_of "$destination")"
  [ "$(dirname "$real")" = "$recordings" ] && [[ "$real" == *.hqrec ]] \
    || fail package-outside-company "That recording is not in $company's recordings folder ($destination)."
  [ -d "$real" ] || fail no-package "There's no saved recording at $real."
  package="$real"
}

build_inputs_hash() {
  (
    cd "$pack_dir/app"
    cat SOURCE Info.plist HQCapture.entitlements
    ls Sources/*.swift | LC_ALL=C sort | xargs cat
    cat Resources/AppIcon.icns
  ) | shasum -a 256 | cut -d' ' -f1
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
  [ "$all" = true ] || args+=(fix "Run: xcode-select --install   (installs Apple's free Command Line Tools). HQ Capture needs an Apple Silicon Mac on macOS 26 or later.")
  json "${args[@]}"
  [ "$all" = true ]
}

# Source guards from the recorder's Scripts/build-clt.sh. Prints the reason on failure.
source_guards() {
  # The SOP drafter must stay a pure text transform: no processes, network, URL opening or
  # model tools, so narration can never trigger a publish or command.
  if grep -nE 'Process\(|NSWorkspace|URLSession|: *Tool\b|tools: *\[[^]]' "$app_src/SOPDraft.swift"; then
    echo "SOPDraft.swift must not run processes, open URLs, use the network or give the model tools"; return 1
  fi
  # Review and export write files only. The exported skill draft is never installed or run.
  if grep -nE 'Process\(|NSWorkspace|URLSession|\.claude/skills' "$app_src/SOPReview.swift" "$app_src/SOPReviewView.swift"; then
    echo "SOP review and export must not run processes, open URLs, use the network or install skills"; return 1
  fi
  # Vault sync goes only through the hq CLI.
  if grep -nE 'URLSession|NSWorkspace|\.claude/skills|reviewed-update' "$app_src/VaultSync.swift"; then
    echo "VaultSync.swift must use only the hq CLI and must not install or replace skills"; return 1
  fi
  if [ "$(grep -cE 'Process\(' "$app_src/VaultSync.swift")" -ne 1 ] \
    || ! grep -qE 'candidates = \["/opt/homebrew/bin/hq", "/usr/local/bin/hq"\]' "$app_src/VaultSync.swift"; then
    echo "VaultSync.swift may start only the hq binary, from one place"; return 1
  fi
}

# Compiles, assembles, signs and checks the app at $1 (the CLT build from the recorder's
# Scripts/build-clt.sh). Appends details to $2.
compile_and_sign() {
  local app="$1" log="$2" bin signed key
  bin="$app/Contents/MacOS/$executable"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  local developer_dir="${DEVELOPER_DIR:-}"
  [ -d /Library/Developer/CommandLineTools ] && developer_dir=/Library/Developer/CommandLineTools
  if ! DEVELOPER_DIR="${developer_dir:-$(xcode-select -p)}" xcrun --sdk macosx swiftc \
      -parse-as-library -swift-version 6 -O -target arm64-apple-macos26.0 \
      -framework AVKit -o "$bin" "$app_src"/*.swift >>"$log" 2>&1; then
    echo build-failed; return 1
  fi
  # SwiftUI's VideoPlayer subclasses AVKit's AVPlayerView. Without AVKit itself the player
  # aborts the first time it is shown.
  otool -L "$bin" | grep -q '/AVKit.framework/' || { echo "not linked against AVKit" >>"$log"; echo check-failed; return 1; }
  cp "$pack_dir/app/Info.plist" "$app/Contents/Info.plist"
  cp "$pack_dir/app/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  if [ ! -s "$app/Contents/Resources/AppIcon.icns" ] \
    || [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")" != "AppIcon" ] \
    || [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist")" != "HQ Capture" ]; then
    echo "the app bundle is missing its icon or the HQ Capture name" >>"$log"; echo check-failed; return 1
  fi
  # The hardened runtime blocks the camera and microphone unless these entitlements are
  # signed in. Without them macOS denies access silently.
  codesign --force --options runtime --entitlements "$pack_dir/app/HQCapture.entitlements" --sign - "$app" >>"$log" 2>&1 \
    && codesign --verify --strict "$app" >>"$log" 2>&1 || { echo sign-failed; return 1; }
  signed="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)"
  for key in com.apple.security.device.camera com.apple.security.device.audio-input; do
    grep -q "$key" <<<"$signed" || { echo "signed app is missing the $key entitlement" >>"$log"; echo check-failed; return 1; }
  done
}

build_is_current() {
  [ -x "$app_path/Contents/MacOS/$executable" ] && [ "$(cat "$stamp_file" 2>/dev/null)" = "$(build_inputs_hash)" ]
}

build_app() {
  local force="${1:-false}" want
  want="$(build_inputs_hash)"
  if [ "$force" != true ] && build_is_current; then
    return 0
  fi
  mkdir -p "$state_dir"
  local log="$state_dir/build.log" tmp="$state_dir/.build-$$" reason
  : >"$log"
  rm -rf "$tmp"; mkdir -p "$tmp"
  if [ -n "${HQ_RECORDER_COMPILE:-}" ]; then
    # shellcheck disable=SC2086
    $HQ_RECORDER_COMPILE "$tmp/HQ Capture.app" >>"$log" 2>&1 \
      || { rm -rf "$tmp"; fail build-failed "HQ Capture did not compile. Details: $log"; }
  else
    if ! cmd_doctor >/dev/null; then
      rm -rf "$tmp"; cmd_doctor; exit 1
    fi
    if ! reason="$(source_guards)"; then
      rm -rf "$tmp"; fail source-guard "The pack's app source failed a safety check: $reason"
    fi
    if ! reason="$(compile_and_sign "$tmp/HQ Capture.app" "$log")"; then
      rm -rf "$tmp"
      case "$reason" in
        sign-failed) fail sign-failed "Signing the locally built app failed. Details: $log" ;;
        check-failed) fail build-check-failed "The built app failed a post-build check. Details: $log" ;;
        *) fail build-failed "HQ Capture did not compile. Details: $log" ;;
      esac
    fi
  fi
  rm -rf "$app_path"
  mkdir -p "$(dirname "$app_path")"
  mv "$tmp/HQ Capture.app" "$app_path"
  rmdir "$tmp"
  printf '%s\n' "$want" >"$stamp_file"
  built=true
  remove_legacy_apps
}

# Removes app bundles that older pack versions built, once the new one is in place:
# "HQ Recorder.app" (0.1.0, in the HQ Recorder state folder) and any LocalScreenRecorder.app
# next to either state folder. Nothing else in those folders is touched.
remove_legacy_apps() {
  local legacy_dir="${HQ_RECORDER_LEGACY_HOME:-$HOME/Library/Application Support/HQ Recorder}" old
  for old in "$legacy_dir/HQ Recorder.app" "$legacy_dir/LocalScreenRecorder.app" "$state_dir/LocalScreenRecorder.app"; do
    [ -d "$old" ] && [ "$old" != "$app_path" ] && rm -rf "$old"
  done
  [ -f "$legacy_dir/build.stamp" ] && [ ! -e "$legacy_dir/HQ Recorder.app" ] && rm -f "$legacy_dir/build.stamp"
  return 0
}

cmd_build() {
  local force=false
  [ "${1:-}" = --force ] && force=true
  built=false
  case "$(current_state)" in
    awaiting-start|recording|finalizing)
      if [ "$force" = true ] || ! build_is_current; then
        fail already-open "HQ Capture is open. Stop it before rebuilding."
      fi ;;
  esac
  build_app "$force"
  json ok true app "$app_path" built "$built"
}

# Prints the app's state, mapping a vanished process to "lost".
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
  # After a save, mediaIssues lists the saved package's track files that are not as long as the
  # recording (from its manifest.json), and issue is the plain note HQ Capture showed.
  python3 -I -c '
import json, os, sys
s = json.load(open(sys.argv[1]))
s["ok"] = True
s["state"] = sys.argv[2]
rec, dest = s.get("recording"), s.get("destination")
if s["state"] == "saved" and isinstance(rec, str) and isinstance(dest, str) and rec.endswith(".hqrec"):
    pkg = os.path.join(dest, os.path.basename(rec))
    try:
        issues = json.load(open(os.path.join(pkg, "manifest.json"))).get("mediaIssues") or []
    except (OSError, ValueError):
        issues = []
    issues = [i for i in issues if isinstance(i, dict) and isinstance(i.get("message"), str)]
    if issues:
        s["mediaIssues"] = issues
        if not s.get("issue"): s["issue"] = issues[0]["message"]
print(json.dumps(s))' "$status_file" "$state"
}

cmd_start() {
  local requested=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --company) requested="${2:-}"; [ -n "$requested" ] || fail bad-argument "--company needs a company."; shift 2 ;;
      *) fail bad-argument "Unknown argument: $1" ;;
    esac
  done
  resolve_company "$requested"

  local state
  state="$(current_state)"
  case "$state" in
    awaiting-start|recording|finalizing)
      fail already-open "HQ Capture is already open (state: $state). Stop it before starting another." ;;
  esac

  mkdir -p "$destination" 2>/dev/null || fail destination-unwritable "Can't create $destination."
  [ -w "$destination" ] || fail destination-unwritable "Can't write to $destination."

  built=false
  build_app

  rm -rf "$control_dir"; mkdir -p "$control_dir"
  local opener="${HQ_RECORDER_OPEN:-open -n}"
  # shellcheck disable=SC2086
  $opener "$app_path" --args --hq-control "$control_dir" --company "$company" --destination "$destination" >/dev/null \
    || fail launch-failed "macOS could not open HQ Capture."

  local i
  for i in $(seq 1 60); do
    [ -f "$status_file" ] && break
    sleep 0.25
  done
  [ -f "$status_file" ] || fail no-status "HQ Capture opened but didn't report back within 15 seconds."
  cmd_status
}

cmd_wait() {
  local limit=540
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout)
        limit="${2:-}"
        [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -ge 1 ] && [ "$limit" -le 3600 ] \
          || fail bad-argument "--timeout needs a whole number of seconds from 1 to 3600."
        shift 2 ;;
      *) fail bad-argument "Unknown argument: $1" ;;
    esac
  done
  [ -f "$status_file" ] || fail not-open "HQ Capture has not been opened. Run start first."
  local deadline=$(( $(date +%s) + limit )) last="" now state line
  while :; do
    state="$(current_state)"
    line="$(python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1]))
out = {"event": "state", "state": sys.argv[2]}
for key in ("paused", "durationSeconds", "recording", "reason", "issue"):
    if s.get(key) is not None: out[key] = s[key]
print(json.dumps(out))' "$status_file" "$state" 2>/dev/null || true)"
    # Print a line when the state, pause or reason changes; duration alone is not a change.
    now="$(python3 -I -c 'import json,sys; j=json.loads(sys.argv[1]); j.pop("durationSeconds", None); print(json.dumps(j, sort_keys=True))' "$line" 2>/dev/null || echo "$state")"
    if [ -n "$line" ] && [ "$now" != "$last" ]; then printf '%s\n' "$line"; last="$now"; fi
    case "$state" in
      saved|failed|closed|lost) cmd_status; return 0 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      cmd_status
      exit 3
    fi
    sleep 1
  done
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

cmd_run() {
  refusal_code=3
  local mode="${1:-}" given="${2:-}"
  [ $# -ge 2 ] || fail bad-argument "usage: run <mode> <package> [args]"
  shift 2
  mode="${mode#--}"
  case "$mode" in
    describe|transcribe|edit|export-video|frame|review-sop|approve-sop|list-frames|draft-sop|export-sop|extract-screen-evidence|sync-package) ;;
    *) fail bad-mode "Unknown mode: $mode. Use describe, transcribe, edit, export-video, frame, review-sop, approve-sop, list-frames, draft-sop, export-sop, extract-screen-evidence or sync-package." ;;
  esac
  local arg
  for arg in "$@"; do
    case "$arg" in
      --describe|--transcribe|--edit|--export-video|--frame|--review-sop|--approve-sop|--list-frames|--draft-sop|--export-sop|--extract-screen-evidence|--sync-package|--measure-sync|--check-access|--retrieve-package|--prepare-skill|--register-skill|--review-package|--hq-control|--company|--destination|--hq-root)
        fail bad-argument "$arg can't be passed to run. Run one mode at a time; the launcher sets the company and folders." ;;
    esac
  done
  resolve_company ""
  resolve_package "$given"

  # Build if needed. While HQ Capture is open, an existing build is used as is so the running
  # app is not replaced underneath it.
  case "$(current_state)" in
    awaiting-start|recording|finalizing) [ -x "$app_path/Contents/MacOS/$executable" ] || build_app ;;
    *) build_app ;;
  esac

  local extra=()
  [ "$mode" = sync-package ] && extra=(--hq-root "$root")
  set +e
  "$app_path/Contents/MacOS/$executable" "--$mode" "$package" "$@" ${extra[@]+"${extra[@]}"}
  local code=$?
  set -e
  exit "$code"
}

# Parses the prompt HQ Capture shows after a save:
#   Continue my HQ Capture recording for <company> at <absolute .hqrec path>: show me what was
#   recorded, then trim, place the camera, export the video and draft the step-by-step guide.
cmd_resume() {
  refusal_code=3
  local prompt="$*" parsed named path
  [ -n "$prompt" ] || fail bad-argument "usage: resume <the prompt HQ Capture showed after saving>"
  parsed="$(python3 -I -c '
import re, sys
m = re.search(r"Continue my HQ Capture recording for ([a-z0-9][a-z0-9-]*) at (/.+?\.hqrec)/?:", " ".join(sys.argv[1].split()))
if m: print(m.group(1)); print(m.group(2))' "$prompt")"
  [ -n "$parsed" ] || fail not-a-resume-prompt "That isn't an HQ Capture resume prompt. It starts with \"Continue my HQ Capture recording for\"."
  named="$(sed -n 1p <<<"$parsed")"
  path="$(sed -n 2p <<<"$parsed")"
  resolve_company ""
  [ "$named" = "$company" ] \
    || fail company-mismatch "That recording belongs to $named, but this session is bound to $company. Open a session in $named and paste the prompt there."
  resolve_package "$path"
  json ok true company "$company" package "$package"
}

case "${1:-}" in
  doctor) shift; cmd_doctor "$@" ;;
  build) shift; cmd_build "$@" ;;
  start) shift; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  run) shift; cmd_run "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  *) echo "usage: hq-record-process.sh {doctor|build [--force]|start [--company <slug>]|status|wait [--timeout <s>]|stop|run <mode> <package> [args]|resume <prompt>}" >&2; exit 2 ;;
esac
