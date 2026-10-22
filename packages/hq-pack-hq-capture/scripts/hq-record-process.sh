#!/usr/bin/env bash
# hq-record-process — launch and control HQ Capture for /record-process.
#
# HQ Capture is built on this Mac from the Swift sources shipped in this pack
# (app/Sources) with Apple's developer tools (the Command Line Tools, or Xcode when they
# cannot build it), then ad-hoc signed. Nothing is
# downloaded and no Apple developer account is needed. The build is redone when
# app/SOURCE or any shipped source, plist, entitlement or icon changes, so a
# pack update rebuilds the app.
#
# Subcommands (each prints JSON on stdout):
#   doctor                        check this Mac can build and run the app
#   build [--force]               build the app if missing or out of date
#   start [--company <slug>] [--record]
#                                 open HQ Capture bound to a company's recordings folder; refused
#                                 with already-open while it is open, or busy while another
#                                 session is opening it. --record then starts recording (as record)
#   record                        start recording in the open HQ Capture, as if the user pressed
#                                 Start: writes start.request and waits for the app's answer.
#                                 Fails with start-blocked (and the blocker as reason) when the app
#                                 can't start, start-timeout when it doesn't answer, not-open,
#                                 already-recording, not-ready or other-company
#   status                        print status.json with the live state; after a save it adds
#                                 mediaIssues from the package and keeps the app's issue note.
#                                 When HQ Capture is open for another company it prints only
#                                 {"ok": true, "state": "busy-other-company"}; once that app has
#                                 exited it prints {"ok": true, "state": "none"}
#   wait [--timeout <seconds>]    block until the state is saved, failed, closed or lost,
#                                 printing one line per change (with issue when the app sets
#                                 one) and the full status last; exit 3 when still open at timeout.
#                                 relaunching (macOS Quit & Reopen after a permission grant) is
#                                 followed until the reopened app reports
#   stop                          write stop.request and wait for the app to close; refused when
#                                 HQ Capture is open for another company; fails with stop-timeout
#                                 when the app is still open and not finalizing after the wait
#   run <mode> <package> [args]   run an agent command headless on a saved recording
#   resume <prompt>               check a pasted resume prompt and print its package
#
# run modes: describe, transcribe, edit, export-video, frame, review-sop, approve-sop,
# list-frames, draft-sop, export-sop, extract-screen-evidence, sync-package. run prints the app's own output and exits with
# its code (0 done, 1 refused, 2 usage or error, 130 cancelled). approve-sop needs --revision
# with the head of the review shown to the user. A launcher refusal
# prints {"ok": false, ...} and exits 3 for run and resume, 1 for the other subcommands.
#
# Every subcommand except doctor and build uses the session's bound company and refuses
# a company, a package or a frame --out path inside another company.
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
#   HQ_RECORDER_LOCK_WAIT  seconds to wait for another build to finish (default 600)
#   HQ_RECORDER_START_WAIT seconds start waits for another start to finish (default 5)
#   HQ_RECORDER_STOP_WAIT  seconds stop waits for the app to act on a stop (default 20)
#   HQ_RECORDER_PROCESS_NAME  process name a live HQ Capture has (default LocalScreenRecorder;
#                        tests only)
#   HQ_RECORDER_RELAUNCH_WAIT seconds a relaunching status counts as open after its app has
#                        quit, while macOS reopens it (default 30)
#   HQ_RECORDER_TAKEOVER_PAUSE seconds to pause between finding a stale lock and taking it over
#                        (tests only)
#   HQ_RECORDER_INSTALL_HOOK command run with the app path after the old app is moved aside and
#                        before the new one is moved in (tests only)
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
lock_dir="$state_dir/.build.lock"
start_lock="$state_dir/.start.lock"
process_name="${HQ_RECORDER_PROCESS_NAME:-$executable}"
held_locks=()
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
  bound="$(HQ_ROOT="$root" hq core hq-session get company_slug 2>/dev/null || true)"
  [ "$bound" = personal ] && bound=""
  if [ -n "$requested" ] && [ -z "$bound" ]; then
    fail no-company "This session isn't working in a company, so --company can't be used. Pick the company for the session first, then run /record-process again."
  fi
  if [ -n "$requested" ] && [ "$requested" != "$bound" ]; then
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

# Covers every shipped app input and the build recipe itself (compile_and_sign, the
# shared swiftc flags and the developer folder choice), so a pack update that only
# changes how the app is built still rebuilds it.
build_inputs_hash() {
  (
    cd "$pack_dir/app"
    cat SOURCE Info.plist HQCapture.entitlements
    find Sources -name '*.swift' -type f -print0 | LC_ALL=C sort -z | xargs -0 cat
    cat Resources/AppIcon.icns
    declare -f compile_and_sign developer_dir developer_dir_candidates toolchain_sdk_ok toolchain_builds_swiftui select_developer_dir swiftc_frontend_args run_swiftc compile_probe_source
    echo "min_sdk_major=$min_sdk_major"
  ) | shasum -a 256 | cut -d' ' -f1
}

# Developer folders to try, best first, one per line: $DEVELOPER_DIR when set, then
# xcode-select's choice, then the Command Line Tools, then /Applications/Xcode.app. Xcode is
# tried last so a Mac whose current tools already build keeps using them; it is reached when
# those tools fail the checks in select_developer_dir, for example Command Line Tools whose
# macOS 27 SDK needs SwiftUI's macro plugin (SwiftUIMacros), which only Xcode includes.
# HQ_RECORDER_XCODE_DIR and HQ_RECORDER_CLT_DIR override the two fixed paths for tests.
developer_dir_candidates() {
  local clt="${HQ_RECORDER_CLT_DIR:-/Library/Developer/CommandLineTools}"
  local xcode="${HQ_RECORDER_XCODE_DIR:-/Applications/Xcode.app/Contents/Developer}"
  {
    [ -z "${DEVELOPER_DIR:-}" ] || printf '%s\n' "$DEVELOPER_DIR"
    xcode-select -p 2>/dev/null || true
    printf '%s\n%s\n' "$clt" "$xcode"
  } | awk 'NF && !seen[$0]++'
}

# The app uses macOS 26 SDK APIs (Liquid Glass, FoundationModels).
min_sdk_major=26

# Prints the macOS SDK version of the developer folder $1, or "missing". True when that SDK is
# macOS $min_sdk_major or newer and has ScreenCaptureKit.
toolchain_sdk_ok() {
  local ver path
  ver="$(DEVELOPER_DIR="$1" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  path="$(DEVELOPER_DIR="$1" xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  printf '%s\n' "${ver:-missing}"
  [[ "${ver%%.*}" =~ ^[0-9]+$ ]] && [ "${ver%%.*}" -ge "$min_sdk_major" ] \
    && [ -n "$path" ] && [ -d "$path/System/Library/Frameworks/ScreenCaptureKit.framework" ]
}

# Use the same bounded, cached feature probe as doctor and the app build.
# Keep its result in this process so signal cleanup owns the compiler lifetime.
probe_err=""
toolchain_builds_swiftui() {
  compile_probe_check "$1" >/dev/null
  probe_err="$compile_probe_detail"
  [ "$compile_probe_result" = true ]
}

# Picks the developer folder that doctor checks and the build uses: the first candidate with a
# Swift compiler, a macOS 26 or newer SDK, and a passing SwiftUI probe. When none passes, the
# first candidate with a new enough SDK (so doctor reports why its probe failed), else the first
# with a compiler (so doctor reports its old SDK). Sets dev_dir (empty when no compiler was
# found), dev_sdk_ok, dev_swiftui and dev_probe_err. Runs once per launcher call. Folders are
# checked to exist before xcrun runs, because xcrun otherwise pops up the install dialog.
dev_dir="" dev_sdk_ok=false dev_swiftui=false dev_probe_err="" dev_selected=false
select_developer_dir() {
  [ "$dev_selected" = true ] && return 0
  dev_selected=true
  local dev first="" sdk_first="" sdk_first_err="" host_version="" host_can_run=true
  host_version="$(sw_vers -productVersion 2>/dev/null || true)"
  case "${host_version%%.*}" in ''|*[!0-9]*) host_can_run=false ;; *) [ "${host_version%%.*}" -ge 26 ] || host_can_run=false ;; esac
  [ "$(uname -m)" = arm64 ] || host_can_run=false
  while IFS= read -r dev; do
    { [ -d "$dev" ] && DEVELOPER_DIR="$dev" xcrun --sdk macosx --find swiftc >/dev/null 2>&1; } || continue
    [ -n "$first" ] || first="$dev"
    toolchain_sdk_ok "$dev" >/dev/null || continue
    if [ "$host_can_run" != true ]; then dev_dir="$dev" dev_sdk_ok=true; return 0; fi
    if toolchain_builds_swiftui "$dev"; then
      dev_dir="$dev" dev_sdk_ok=true dev_swiftui=true dev_probe_err=""
      return 0
    fi
    [ -n "$sdk_first" ] || { sdk_first="$dev"; sdk_first_err="$probe_err"; }
  done < <(developer_dir_candidates)
  if [ -n "$sdk_first" ]; then
    dev_dir="$sdk_first" dev_sdk_ok=true dev_probe_err="$sdk_first_err"
  else
    dev_dir="$first"
  fi
}

# Prints a JSON string literal for $1. doctor uses this so it works without python3.
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"
  printf '"%s"' "$s"
}

# Frontend flags shared by the real build and the doctor's typecheck probe.
swiftc_frontend_args() {
  printf '%s\n' -parse-as-library -swift-version 6 -O -target arm64-apple-macos26.0 -framework AVKit
}

# Compiles with the same developer directory, SDK and flags as the build.
# Extra arguments are the output and sources, or -typecheck and a probe file.
developer_dir() {
  select_developer_dir
  printf '%s\n' "$dev_dir"
}

run_swiftc() {
  local arg args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(swiftc_frontend_args)
  DEVELOPER_DIR="$(developer_dir)" xcrun --sdk macosx swiftc "${args[@]}" "$@"
}

# The SwiftUI and Observation features the app uses: State via SwiftUI.State
# (not the State macro), @Observable, and a Binding.
compile_probe_source() {
  cat <<'SWIFT'
import Observation
import SwiftUI

typealias CaptureState<Value> = SwiftUI.State<Value>

@MainActor
@Observable
final class DoctorProbeModel {
    var enabled = false
}

@MainActor
struct DoctorProbeView: View {
    @CaptureState private var ready = false
    var model: DoctorProbeModel

    var body: some View {
        VStack {
            Toggle("Ready", isOn: $ready)
            Toggle("Enabled", isOn: Binding(
                get: { model.enabled },
                set: { model.enabled = $0 }
            ))
        }
        .glassEffect(.regular)
    }
}
SWIFT
}

# What a customer runs to replace this pack. `hq install` treats a bare slug as
# the marketplace id, and this product's slug is hq-capture. `xcode-select
# --install` refuses when Command Line Tools are already present, and a tools
# update does not add the Xcode-only Swift macro plugin.
capture_update_fix() {
  printf '%s\n' 'Update HQ Capture with: hq install hq-capture. If it still fails, update the Command Line Tools in System Settings > General > Software Update.'
}

# xcrun --show-sdk-path is usually the MacOSX.sdk symlink. pwd -P is the
# versioned directory that link points at.
resolve_sdk_path() {
  local p="$1" resolved=""
  if [ -n "$p" ] && [ -d "$p" ]; then
    resolved="$(cd "$p" && pwd -P)" || resolved=""
  fi
  if [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
  else
    printf '%s\n' "${p:-missing}"
  fi
}

# Last lines of a probe log, as one line. Doctor records are tab-separated,
# so a newline in the detail would split the record.
probe_log_tail() {
  local log="$1" text
  [ -s "$log" ] || return 0
  text="$(tail -n 40 "$log" | tr '\n\t\r' '   ' | sed 's/[[:space:]]*$//')"
  printf '%s' "$text"
}

# Typecheck with the build toolchain, bounded so a hung swiftc cannot hold the
# build lock. macOS has no timeout(1). Exit 124 means the limit was reached.
# 120s: a cold swiftc on the GitHub macOS runner was still running at 30s.
# The compiler is its own process group so the alarm can kill it, and it
# ignores SIGTTIN so that group is not stopped by a terminal.
# exec replaces this process so the caller's probe pid is perl.
run_probe_typecheck() {
  local dev="$1" limit="${HQ_RECORDER_PROBE_TIMEOUT:-120}" arg args=()
  shift
  case "$limit" in
    ''|*[!0-9]*) limit=120 ;;
  esac
  if [ "$limit" -lt 1 ]; then limit=120; fi
  while IFS= read -r arg; do args+=("$arg"); done < <(swiftc_frontend_args)
  exec perl -MPOSIX -MErrno=EINTR -e '
    my $limit = shift @ARGV;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
      $SIG{TTIN} = "IGNORE";
      $SIG{TTOU} = "IGNORE";
      setpgid(0, 0);
      exec @ARGV or die "exec: $!";
    }
    setpgid($pid, $pid);
    # Keep the child PID reserved until the entire owned group has received
    # escalation. Reaping first could allow a reused PID/group to be targeted.
    my $terminate = sub {
      my ($code) = @_;
      $SIG{ALRM} = $SIG{TERM} = $SIG{INT} = "IGNORE";
      alarm 0;
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      my $got;
      do { $got = waitpid($pid, 0); } while ($got == -1 && $! == EINTR);
      exit $code;
    };
    $SIG{ALRM} = sub { $terminate->(124); };
    $SIG{TERM} = sub { $terminate->(143); };
    $SIG{INT}  = sub { $terminate->(130); };
    alarm $limit;
    my $got = waitpid($pid, 0);
    while ($got == -1 && $! == EINTR) {
      $got = waitpid($pid, 0);
    }
    alarm 0;
    my $status = $?;
    exit 1 if $got < 0;
    exit($status >> 8) if ($status & 127) == 0;
    exit(128 + ($status & 127));
  ' "$limit" \
    env "DEVELOPER_DIR=$dev" \
    xcrun --sdk macosx swiftc "${args[@]}" -typecheck "$@"
}

# Interrupt during the probe: kill the compiler and remove the temp dir.
# Exiting lets the build lock's EXIT trap release the lock.
# TERM the probe and every descendant. Killing only the top pid leaves the
# compiler running when a shell sits between this process and perl.
kill_probe_tree() {
  local pid="$1" child
  [ -n "$pid" ] || return 0
  for child in $(ps -ax -o pid=,ppid= | awk -v p="$pid" '$2 == p { print $1 }'); do
    kill_probe_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

cleanup_probe_signal() {
  local status="$1"
  if [ -n "${HQ_DOCTOR_PROBE_PID:-}" ]; then
    kill_probe_tree "$HQ_DOCTOR_PROBE_PID"
    wait "$HQ_DOCTOR_PROBE_PID" 2>/dev/null || true
  fi
  if [ -n "${HQ_DOCTOR_PROBE_TMP:-}" ]; then
    rm -rf "$HQ_DOCTOR_PROBE_TMP"
    HQ_DOCTOR_PROBE_TMP=
  fi
  if [ -n "${HQ_DOCTOR_LINES:-}" ]; then
    rm -f "$HQ_DOCTOR_LINES"
    HQ_DOCTOR_LINES=
  fi
  exit "$status"
}

# Typechecks the probe with the build toolchain. Prints one doctor line.
# A passing result is cached by the reported SDK path, the resolved SDK
# directory, the SDK version, the Swift version, the swiftc file, the frontend
# flags and the probe source. A failure is not cached, so the next doctor
# retries it.
compile_probe_result=false compile_probe_detail=""
compile_probe_check() {
  local dev sdk_path sdk_real sdk_ver swift_raw swift_ver swiftc_bin swiftc_id probe_src identity cache
  local cached_id cached_ok cached_detail tmp log result detail probe_rc evidence
  dev="${1:-$(developer_dir)}"
  sdk_path="$(DEVELOPER_DIR="$dev" xcrun --sdk macosx --show-sdk-path 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  sdk_ver="$(DEVELOPER_DIR="$dev" xcrun --sdk macosx --show-sdk-version 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  swift_raw="$(DEVELOPER_DIR="$dev" xcrun --sdk macosx swiftc --version 2>/dev/null || true)"
  swift_ver="$(printf '%s\n' "$swift_raw" | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1 || true)"
  swiftc_bin="$(DEVELOPER_DIR="$dev" xcrun --sdk macosx --find swiftc 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  if [ -n "$swiftc_bin" ] && [ -e "$swiftc_bin" ]; then
    # GNU stat can print filesystem data before rejecting the BSD format.
    # Discard output from a failed attempt instead of contaminating identity.
    if swiftc_id="$(stat -f '%m:%i' "$swiftc_bin" 2>/dev/null)"; then
      :
    else
      swiftc_id="$(stat -c '%Y:%i' "$swiftc_bin" 2>/dev/null || echo missing)"
    fi
  else
    swiftc_id=missing
  fi
  [ -n "$sdk_path" ] || sdk_path=missing
  sdk_real="$(resolve_sdk_path "$sdk_path")"
  [ -n "$sdk_ver" ] || sdk_ver=missing
  [ -n "$swift_ver" ] || swift_ver=missing
  probe_src="$(compile_probe_source)"
  # The reported SDK path stays the MacOSX.sdk symlink across a tools update.
  # The resolved directory and the SDK version change when that link moves.
  # The compiler file's mtime and inode catch a tools update that keeps both.
  identity="$(
    {
      printf '%s\n' doctor-probe-v3 "$dev" "$sdk_path" "$sdk_real" "$sdk_ver" "$swift_ver" "$swiftc_id"
      swiftc_frontend_args
      printf '%s' "$probe_src"
    } | shasum -a 256 | awk '{print $1}'
  )"
  cache="$state_dir/.doctor-probe.cache"
  if [ -f "$cache" ]; then
    IFS=$'\t' read -r cached_id cached_ok cached_detail <"$cache" || true
    if [ "$cached_id" = "$identity" ] && [ "$cached_ok" = true ]; then
      compile_probe_result=true compile_probe_detail="$cached_detail"
      printf 'compile_probe\ttrue\t%s\n' "$cached_detail"
      return 0
    fi
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/hq-capture-doctor.XXXXXX")"
  HQ_DOCTOR_PROBE_TMP="$tmp"
  trap 'cleanup_probe_signal 130' INT
  trap 'cleanup_probe_signal 143' TERM
  printf '%s\n' "$probe_src" >"$tmp/Probe.swift"
  log="$tmp/probe.log"
  probe_rc=0
  HQ_DOCTOR_PROBE_PID=
  # Background plus wait, so an interrupt runs the trap instead of sitting
  # inside a foreground swiftc until it exits.
  run_probe_typecheck "$dev" "$tmp/Probe.swift" >"$log" 2>&1 &
  HQ_DOCTOR_PROBE_PID=$!
  wait "$HQ_DOCTOR_PROBE_PID" || probe_rc=$?
  HQ_DOCTOR_PROBE_PID=
  if [ "$probe_rc" -eq 0 ]; then
    result=true
    detail="Swift ${swift_ver}, macOS SDK ${sdk_ver}"
  else
    result=false
    evidence="$(probe_log_tail "$log")"
    if [ "$probe_rc" -eq 124 ]; then
      detail="Swift ${swift_ver}, macOS SDK ${sdk_ver}: check timed out"
    elif grep -Eq 'plugin for module .+ not found' "$log"; then
      detail="Swift ${swift_ver}, macOS SDK ${sdk_ver}: missing Swift macro plugin (plugin for module not found)"
    else
      detail="Swift ${swift_ver}, macOS SDK ${sdk_ver}: the toolchain could not typecheck SwiftUI State, Observable and Binding"
    fi
    # Keep the compiler's own output unless it is the plugin error, which
    # already has a stable explanation. A timeout with no output stays short.
    if ! grep -Eq 'plugin for module .+ not found' "$log" && [ -n "$evidence" ]; then
      detail="$detail: $evidence"
    fi
  fi
  rm -rf "$tmp"
  HQ_DOCTOR_PROBE_TMP=
  trap - INT TERM
  if [ "$result" = true ] && mkdir -p "$state_dir" 2>/dev/null; then
    printf '%s\t%s\t%s\n' "$identity" "$result" "$detail" >"$state_dir/.doctor-probe.cache.$$" \
      && mv -f "$state_dir/.doctor-probe.cache.$$" "$cache" || true
  fi
  compile_probe_result="$result" compile_probe_detail="$detail"
  printf 'compile_probe\t%s\t%s\n' "$result" "$detail"
}

doctor_checks() {
  # Prints "name<TAB>ok<TAB>detail" lines.
  local os arch ver dev swift_ok sdk_ok sdk_ver ready=true
  HQ_DOCTOR_PROBE_READY=false
  os="$(uname -s)"; arch="$(uname -m)"
  printf 'macos\t%s\t%s\n' "$([ "$os" = Darwin ] && echo true || echo false)" "$os"
  printf 'apple_silicon\t%s\t%s\n' "$([ "$arch" = arm64 ] && echo true || echo false)" "$arch"
  [ "$arch" = arm64 ] || ready=false
  if [ "$os" = Darwin ]; then
    ver="$(sw_vers -productVersion)"
    printf 'macos_26_or_later\t%s\t%s\n' "$([ "${ver%%.*}" -ge 26 ] && echo true || echo false)" "$ver"
    [ "${ver%%.*}" -ge 26 ] || ready=false
    # Find the developer folder before calling xcrun, which otherwise pops up the install
    # dialog, and use the same folder the build uses.
    dev="$dev_dir"
    swift_ok=false
    [ -n "$dev" ] && swift_ok=true
    printf 'command_line_tools\t%s\t%s\n' "$swift_ok" "${dev:-missing}"
    [ "$swift_ok" = true ] || ready=false
    sdk_ok="$dev_sdk_ok" sdk_ver=missing
    if [ "$swift_ok" = true ]; then sdk_ver="$(toolchain_sdk_ok "$dev" || true)"; fi
    printf 'macos_sdk\t%s\t%s\n' "$sdk_ok" "$sdk_ver"
    printf 'swiftui_macros\t%s\t%s\n' "$dev_swiftui" "${dev:-missing}"
    [ "$sdk_ok" = true ] || ready=false
    # Skip the probe when an earlier check already failed, so that failure keeps
    # the install fix instead of a compile message about tools that are not usable.
    # The probe itself runs in cmd_doctor. An interrupt is delivered to that
    # process; a process substitution would keep the temp dir in a child.
    if [ "$ready" = true ]; then HQ_DOCTOR_PROBE_READY=true; fi
  fi
}

# Builds its JSON in bash, so the fix line still prints on a Mac without python3.
cmd_doctor() {
  local body="" all=true name ok detail probe_failed=false others_failed=false probe_detail="" message
  local lines host_version="" selected_sdk=""
  lines="$(mktemp "${TMPDIR:-/tmp}/hq-capture-doctor-lines.XXXXXX")"
  HQ_DOCTOR_LINES="$lines"
  [ "$(uname -s)" != Darwin ] || select_developer_dir
  doctor_checks >"$lines"
  if [ "${HQ_DOCTOR_PROBE_READY:-false}" = true ]; then
    printf 'compile_probe\t%s\t%s\n' "$dev_swiftui" "${dev_probe_err:-$compile_probe_detail}" >>"$lines"
  fi
  while IFS=$'\t' read -r name ok detail; do
    [ -n "$name" ] || continue
    [ "$name" != macos_sdk ] || selected_sdk="$detail"
    body+=", $(json_string "$name"): $ok, $(json_string "${name}_detail"): $(json_string "$detail")"
    if [ "$ok" != true ]; then
      all=false
      if [ "$name" = compile_probe ] || [ "$name" = swiftui_macros ]; then
        probe_failed=true
        probe_detail="$detail"
      else
        others_failed=true
      fi
    fi
  done <"$lines"
  rm -f "$lines"
  HQ_DOCTOR_LINES=
  if [ "$all" != true ]; then
    if [ "$probe_failed" = true ] && [ "$others_failed" = false ]; then
      if printf '%s\n' "$probe_detail" | grep -q 'check timed out'; then
        message="The compile check timed out."
      else
        message="The installed Command Line Tools cannot build this version of HQ Capture."
      fi
      body+=", \"message\": $(json_string "$message")"
      body+=", \"fix\": $(json_string "$(capture_update_fix)")"
    else
      host_version="$(sw_vers -productVersion 2>/dev/null || true)"
      if [[ "${host_version%%.*}" =~ ^[0-9]+$ ]] && [ "${host_version%%.*}" -lt 26 ]; then
        body+=", \"fix\": $(json_string "Upgrade this Mac to macOS 26 or later. Installing Command Line Tools alone cannot make HQ Capture run on macOS $host_version.")"
      elif [ -n "$dev_dir" ] && [ "$dev_sdk_ok" != true ]; then
        body+=", \"fix\": $(json_string "The developer tools at $dev_dir have macOS SDK $selected_sdk. HQ Capture needs the macOS 26 SDK or newer. Update Command Line Tools in Software Update, or use a current Xcode.")"
      else
        body+=", \"fix\": $(json_string "Run: xcode-select --install   (installs Apple's free Command Line Tools). HQ Capture needs an Apple Silicon Mac on macOS 26 or later.")"
      fi
    fi
  fi
  printf '{"ok": %s%s}\n' "$all" "$body"
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
  if grep -nE 'Process\(|NSWorkspace|URLSession|\.claude/skills' "$app_src/SOPReview.swift"; then
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
  if ! run_swiftc -o "$bin" "$app_src"/*.swift >>"$log" 2>&1; then
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

# Locks are directories holding the owner's pid and, on the next line, that process's start
# time (ps lstart). The file is written to a temp file inside the new directory and renamed into
# place, so a reader sees either no pid or the whole file. A lock is stale when its owner has
# exited, when its pid now belongs to a process with a different start time (macOS reused the
# pid), or when it has no pid and is older than 30 seconds (its owner died between creating it and
# writing the pid).

# Prints the start time of process $1, or nothing.
proc_start() { ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//; s/ *$//' || true; }

claim_lock() {
  mkdir "$1" 2>/dev/null || return 1
  printf '%s\n%s\n' "$$" "$(proc_start $$)" >"$1/.pid.$$" && mv -f "$1/.pid.$$" "$1/pid"
  held_locks+=("$1")
  trap release_locks EXIT
}

# Clears the lock at $1 when it is stale and takes it, in one step. Takeovers run one at a time
# under a kernel file lock (released by the kernel if the process dies), and the stale lock is
# checked again inside it, so two launchers that both found it stale cannot both take it: the
# second sees the first one's live lock. The stale lock is renamed aside (an atomic rename, checked
# to be the same directory that was judged stale) before the new one is created with mkdir.
takeover_lock() {
  python3 -I - "$1" "$$" "$(proc_start $$)" "${HQ_RECORDER_TAKEOVER_PAUSE:-0}" <<'PY'
import fcntl, os, shutil, subprocess, sys, time, uuid
lock, pid, start, pause = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4] or 0)
guard = open(os.path.join(os.path.dirname(lock), ".lock-takeover"), "a")
fcntl.flock(guard, fcntl.LOCK_EX)

def started(p):
    out = subprocess.run(["ps", "-p", p, "-o", "lstart="], capture_output=True, text=True).stdout
    return out.strip()

def stale_inode():
    """The lock's inode when it is stale, None when it is gone, False when it is held."""
    try:
        st = os.stat(lock)
    except FileNotFoundError:
        return None
    try:
        lines = open(os.path.join(lock, "pid")).read().split("\n")
    except OSError:
        lines = []
    owner = lines[0].strip() if lines else ""
    if not owner:
        return st.st_ino if time.time() - st.st_mtime >= 30 else False
    if not owner.isdigit():
        return st.st_ino
    try:
        os.kill(int(owner), 0)
    except ProcessLookupError:
        return st.st_ino
    except PermissionError:
        pass
    recorded = lines[1].strip() if len(lines) > 1 else ""
    if recorded and started(owner) != recorded:
        return st.st_ino
    return False

def claim():
    try:
        os.mkdir(lock)
    except FileExistsError:
        sys.exit(1)
    tmp = os.path.join(lock, ".pid.%s" % pid)
    with open(tmp, "w") as f:
        f.write("%s\n%s\n" % (pid, start))
    os.rename(tmp, os.path.join(lock, "pid"))
    sys.exit(0)

inode = stale_inode()
if inode is False:
    sys.exit(1)
if inode is None:
    claim()
if pause:
    time.sleep(pause)  # tests only: widens the window between the check and the takeover
aside = "%s.stale.%s" % (lock, uuid.uuid4().hex)
try:
    os.rename(lock, aside)
except FileNotFoundError:
    claim()
if os.stat(aside).st_ino != inode:
    # Not the directory judged stale. Put it back; a non-empty directory is never replaced.
    try:
        os.rename(aside, lock)
    except OSError:
        pass
    sys.exit(1)
shutil.rmtree(aside, ignore_errors=True)
claim()
PY
}

# Takes the lock at $1, clearing it first when it is stale. Returns 1 when another live
# process holds it.
try_lock() {
  claim_lock "$1" && return 0
  if takeover_lock "$1"; then
    held_locks+=("$1")
    trap release_locks EXIT
    return 0
  fi
  return 1
}

# True while the lock at $1 still names this process and its start time.
lock_is_mine() {
  [ "$(sed -n 1p "$1/pid" 2>/dev/null)" = "$$" ] && [ "$(sed -n 2p "$1/pid" 2>/dev/null)" = "$(proc_start $$)" ]
}

release_lock() {
  lock_is_mine "$1" && rm -rf "$1"
  return 0
}

# Moves the new app at $1 to $app_path. The old app is moved aside first, and the new one is moved
# in with a rename that fails when anything is at $app_path, so it can never end up inside another
# app bundle. Returns 1 when something appeared at $app_path meanwhile.
install_app() {
  local new="$1" aside="$state_dir/.old-app-$$"
  mkdir -p "$(dirname "$app_path")"
  rm -rf "$aside"
  if [ -e "$app_path" ] || [ -L "$app_path" ]; then mv "$app_path" "$aside"; fi
  # shellcheck disable=SC2086
  [ -z "${HQ_RECORDER_INSTALL_HOOK:-}" ] || $HQ_RECORDER_INSTALL_HOOK "$app_path"
  if ! python3 -I -c '
import os, sys
new, dest = sys.argv[1:]
if os.path.lexists(dest): sys.exit(1)
os.rename(new, dest)' "$new" "$app_path" 2>/dev/null; then
    rm -rf "$aside"
    return 1
  fi
  rm -rf "$aside"
}

release_locks() {
  local dir
  for dir in ${held_locks[@]+"${held_locks[@]}"}; do release_lock "$dir"; done
}

# Takes the build lock, so two launchers never build into the same app at once.
acquire_build_lock() {
  local waited=0 limit="${HQ_RECORDER_LOCK_WAIT:-600}"
  mkdir -p "$state_dir"
  until try_lock "$lock_dir"; do
    [ "$waited" -lt "$limit" ] || fail build-busy "Another HQ Capture build is still running. Try again when it finishes."
    sleep 1; waited=$((waited + 1))
  done
}

# Takes the start lock, held from the open check until the new app has written its first
# status, so two starts never open two apps. While another start holds it, waits briefly and
# reports already-open as soon as that start's app is open, or busy when the wait runs out.
acquire_start_lock() {
  local waited=0 limit="${HQ_RECORDER_START_WAIT:-5}"
  mkdir -p "$state_dir"
  until try_lock "$start_lock"; do
    if app_is_open; then
      fail already-open "HQ Capture is already open (state: $(current_state)). Stop it before starting another."
    fi
    [ "$waited" -lt $((limit * 4)) ] || fail busy "HQ Capture is being opened by another session right now. Run status in a moment to see it."
    sleep 0.25; waited=$((waited + 1))
  done
}

# A missing Swift macro plugin means these Command Line Tools cannot build this
# pack. Name that cause. Other failures still point at the build log.
build_failed_message() {
  local log="$1"
  if grep -Eq 'plugin for module .+ not found' "$log" 2>/dev/null; then
    printf '%s\n' "The installed Command Line Tools cannot build this version of HQ Capture. $(capture_update_fix) Details: $log"
  else
    printf '%s\n' "HQ Capture did not compile. Details: $log"
  fi
}

build_app() {
  local force="${1:-false}" want
  want="$(build_inputs_hash)"
  if [ "$force" != true ] && build_is_current; then
    return 0
  fi
  acquire_build_lock
  # Another launcher may have finished the same build while this one waited.
  if [ "$force" != true ] && build_is_current; then
    release_lock "$lock_dir"
    return 0
  fi
  local log="$state_dir/build.log" tmp="$state_dir/.build-$$" reason doctor_out
  : >"$log"
  rm -rf "$tmp"; mkdir -p "$tmp"
  if [ -n "${HQ_RECORDER_COMPILE:-}" ]; then
    # shellcheck disable=SC2086
    $HQ_RECORDER_COMPILE "$tmp/HQ Capture.app" >>"$log" 2>&1 \
      || { rm -rf "$tmp"; fail build-failed "$(build_failed_message "$log")"; }
  else
    # One doctor run. A second call would typecheck again, because a failure
    # is not cached, and would hold the build lock for that long.
    if ! doctor_out="$(cmd_doctor)"; then
      rm -rf "$tmp"
      printf '%s\n' "$doctor_out"
      exit 1
    fi
    if ! reason="$(source_guards)"; then
      rm -rf "$tmp"; fail source-guard "The pack's app source failed a safety check: $reason"
    fi
    if ! reason="$(compile_and_sign "$tmp/HQ Capture.app" "$log")"; then
      rm -rf "$tmp"
      case "$reason" in
        sign-failed) fail sign-failed "Signing the locally built app failed. Details: $log" ;;
        check-failed) fail build-check-failed "The built app failed a post-build check. Details: $log" ;;
        *) fail build-failed "$(build_failed_message "$log")" ;;
      esac
    fi
  fi
  # Install only while this launcher still holds the build lock.
  lock_is_mine "$lock_dir" \
    || { rm -rf "$tmp"; fail build-busy "Another HQ Capture build took over while this one was building. Try again when it finishes."; }
  install_app "$tmp/HQ Capture.app" \
    || { rm -rf "$tmp"; fail install-conflict "Another HQ Capture app appeared at $app_path during the install. Run build again."; }
  rmdir "$tmp"
  printf '%s\n' "$want" >"$stamp_file"
  built=true
  release_lock "$lock_dir"
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
  if app_is_open && { [ "$force" = true ] || ! build_is_current; }; then
    fail already-open "HQ Capture is open. Stop it before rebuilding."
  fi
  build_app "$force"
  json ok true app "$app_path" built "$built"
}

# True when $1 is a running HQ Capture process. Checking the process name as well as that the
# pid is alive means a pid that macOS has since given to another program does not count.
is_app_process() {
  local pid="$1" comm
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  comm="$(ps -p "$pid" -o comm= 2>/dev/null)" || return 1
  comm="${comm%"${comm##*[![:space:]]}"}"
  [ "${comm##*/}" = "$process_name" ]
}

status_pid() {
  python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1])).get("pid", ""))' "$status_file" 2>/dev/null || true
}

# Prints the app's state, mapping a vanished process to "lost".
current_state() {
  [ -f "$status_file" ] || { echo none; return; }
  local state
  state="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$status_file")"
  case "$state" in
    closed|saved|failed) echo "$state" ;;
    # The app quit for macOS Quit & Reopen after a Screen Recording grant. It stays relaunching
    # while that app is still quitting and for a short wait after, while macOS reopens it and the
    # reopened app writes its own status. If none does, it was a plain quit: closed.
    relaunching)
      if is_app_process "$(status_pid)" || [ "$(status_age)" -lt "${HQ_RECORDER_RELAUNCH_WAIT:-30}" ]; then
        echo relaunching
      else
        echo closed
      fi ;;
    *) if is_app_process "$(status_pid)"; then echo "$state"; else echo lost; fi ;;
  esac
}

# Seconds since status.json was last written.
status_age() {
  python3 -I -c 'import os,sys,time;print(int(time.time()-os.stat(sys.argv[1]).st_mtime))' "$status_file" 2>/dev/null || echo 0
}

# True while HQ Capture's process is running: awaiting start, recording or finalizing, or
# still showing a saved or failed recording in its window, or being reopened by macOS.
app_is_open() {
  case "$(current_state)" in
    awaiting-start|recording|finalizing|relaunching) return 0 ;;
    saved|failed) is_app_process "$(status_pid)" ;;
    *) return 1 ;;
  esac
}

# Prints the company status.json belongs to, or nothing.
status_company() {
  python3 -I -c 'import json,sys;c=json.load(open(sys.argv[1])).get("company");print(c if isinstance(c,str) else "")' "$status_file" 2>/dev/null || true
}

# True when HQ Capture's status belongs to a company other than the bound one. A status
# with no company counts as another company's.
status_for_other_company() {
  [ -f "$status_file" ] && [ "$(status_company)" != "$company" ]
}

# True when HQ Capture is open for another company. Once that company's app has exited, its
# status no longer blocks this company and none of it is shown here.
open_for_other_company() {
  status_for_other_company && app_is_open
}

busy_other_company() { printf '{"ok": true, "state": "busy-other-company"}\n'; }

cmd_status() {
  resolve_company ""
  if open_for_other_company; then busy_other_company; return; fi
  if status_for_other_company; then json ok true state none; return; fi
  print_status
}

print_status() {
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
  local requested="" record=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --company) requested="${2:-}"; [ -n "$requested" ] || fail bad-argument "--company needs a company."; shift 2 ;;
      --record) record=true; shift ;;
      *) fail bad-argument "Unknown argument: $1" ;;
    esac
  done
  resolve_company "$requested"

  acquire_start_lock
  if app_is_open; then
    fail already-open "HQ Capture is already open (state: $(current_state)). Stop it before starting another."
  fi

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
  release_lock "$start_lock"
  if [ "$record" = true ]; then record_now; else print_status; fi
}

cmd_record() {
  [ $# -eq 0 ] || fail bad-argument "Unknown argument: $1"
  resolve_company ""
  record_now
}

# Asks the open HQ Capture to start recording, as if the user pressed Start.
#
# start.request holds the requesting company. The app accepts it by renaming it to
# start.accepted (so a withdrawn request can never be accepted later), checks the company,
# writes its answer to status.json, and then removes start.accepted. The answer is recording
# when it started, awaiting-start with the blocker as the reason when it could not, or failed
# when capture did not start.
#
# The start lock is held from the company and open checks until the request is in place, so a
# stop and a start for another company cannot replace the control folder in between.
record_now() {
  local waited=0
  until try_lock "$start_lock"; do
    [ "$waited" -lt 20 ] || fail busy "HQ Capture is being opened by another session right now. Run status in a moment."
    sleep 0.25; waited=$((waited + 1))
  done
  if open_for_other_company; then
    release_lock "$start_lock"
    fail other-company "HQ Capture is open for another company. Start it from a session in that company."
  fi
  if status_for_other_company || ! app_is_open; then
    release_lock "$start_lock"
    fail not-open "HQ Capture is not open. Run start first."
  fi
  local state
  state="$(current_state)"
  case "$state" in
    awaiting-start) ;;
    recording) release_lock "$start_lock"; fail already-recording "HQ Capture is already recording." ;;
    *) release_lock "$start_lock"; fail not-ready "HQ Capture can't start a recording now (state: $state)." ;;
  esac
  local request="$control_dir/start.request" accepted="$control_dir/start.accepted"
  local i limit="${HQ_RECORDER_RECORD_WAIT:-20}"
  rm -f "$accepted"
  printf '%s\n' "$company" >"$request.$$"
  mv "$request.$$" "$request"
  release_lock "$start_lock"
  for i in $(seq 1 $((limit * 4))); do
    [ -e "$request" ] || break
    sleep 0.25
  done
  # Withdraw a request the app has not accepted. Removing it fails only when the app renamed it
  # to start.accepted first, and then the app is starting and its answer is still to come.
  if python3 -I -c 'import os,sys; os.remove(sys.argv[1])' "$request" 2>/dev/null; then
    fail start-timeout "HQ Capture did not answer the start request within $limit seconds. The request was withdrawn."
  fi
  for i in $(seq 1 $((limit * 4))); do
    [ -e "$accepted" ] || break
    sleep 0.25
  done
  if [ -e "$accepted" ]; then
    fail start-pending "HQ Capture accepted the start and is still starting. Run status to see when it is recording."
  fi
  if status_for_other_company; then
    fail other-company "HQ Capture is open for another company. Start it from a session in that company."
  fi
  state="$(current_state)"
  case "$state" in
    recording) print_status ;;
    awaiting-start)
      local reason
      reason="$(python3 -I -c 'import json,sys;r=json.load(open(sys.argv[1])).get("reason");print(r if isinstance(r,str) else "")' "$status_file" 2>/dev/null || true)"
      json ok false error start-blocked reason "${reason:-not-ready}" \
        message "HQ Capture could not start recording (${reason:-not ready}). Fix it in the HQ Capture window, then run record again."
      exit 1 ;;
    *)
      print_status >&2
      fail start-failed "HQ Capture did not start recording (state: $state)." ;;
  esac
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
  resolve_company ""
  if [ ! -f "$status_file" ] || { status_for_other_company && ! app_is_open; }; then
    fail not-open "HQ Capture has not been opened. Run start first."
  fi
  local deadline=$(( $(date +%s) + limit )) last="" now state line
  while :; do
    # Checked on every pass: another company's session may start HQ Capture while this waits.
    if open_for_other_company; then busy_other_company; return 0; fi
    if status_for_other_company; then json ok true state none; return 0; fi
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
      saved|failed|closed|lost) print_status; return 0 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      print_status
      exit 3
    fi
    sleep 1
  done
}

cmd_stop() {
  resolve_company ""
  if open_for_other_company; then
    fail other-company "HQ Capture is open for another company. Stop it from a session in that company."
  fi
  if status_for_other_company; then json ok true state none; return; fi
  # A saved or failed app that is still showing its window is asked to quit too, and keeps
  # its saved or failed status as it quits.
  if ! app_is_open; then print_status; return; fi
  : >"$control_dir/stop.request"
  local i limit="${HQ_RECORDER_STOP_WAIT:-20}" state
  for i in $(seq 1 $((limit * 4))); do
    app_is_open || break
    sleep 0.25
  done
  # Still open after the wait: finalizing means the files are being written, a saved or failed
  # app keeps its result, and a relaunching app is not recording (the reopened app finds
  # stop.request and quits), so those are reported as they are. Any other state means the app
  # has not acted on the stop and may still be recording.
  if app_is_open; then
    state="$(current_state)"
    case "$state" in
      finalizing|saved|failed|relaunching) ;;
      *) fail stop-timeout "HQ Capture did not stop within $limit seconds and may still be recording (status: $state). Run status to check." ;;
    esac
  fi
  print_status
}

# Refuses a frame --out path inside another company's folder (companies/<slug>/ for any slug
# but the bound one, or loose in companies/). Paths elsewhere, such as $TMPDIR, are allowed.
# The path is resolved through its existing parents, and every companies/<slug> entry is resolved
# too, so a company folder that is a symlink to somewhere outside companies/ still counts as that
# company's, however the path reaches it. When company folders nest, the deepest one decides.
check_frame_out() {
  local out="" real
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:-}"; shift; [ $# -eq 0 ] || shift ;;
      --out=*) out="${1#--out=}"; shift ;;
      *) shift ;;
    esac
  done
  [ -n "$out" ] || return 0
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  real="$(realpath_of "$out")"
  python3 -I - "$real" "$root/companies" "$company" <<'PY' || fail out-outside-company "That frame path is in another company's folder. Save it in $company's folder or a temporary folder."
import os, sys
real, companies, mine = sys.argv[1:]

def inside(path, folder):
    return path == folder or path.startswith(folder.rstrip("/") + "/")

owner, owner_dir = None, ""
for entry in os.listdir(companies):
    folder = os.path.realpath(os.path.join(companies, entry))
    if os.path.isdir(folder) and inside(real, folder) and len(folder) > len(owner_dir):
        owner, owner_dir = entry, folder
if owner is not None:
    sys.exit(0 if owner == mine and real != owner_dir else 1)
# Loose in companies/ (or companies/ itself) belongs to no company and is refused too.
sys.exit(1 if inside(real, os.path.realpath(companies)) else 0)
PY
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
  # Approval binds to the review revision the user was shown: approve-sop must name it, so a
  # revision saved after that (by another session or command) is refused instead of approved.
  if [ "$mode" = approve-sop ]; then
    local next="" shown=""
    for arg in "$@"; do
      [ "$next" = 1 ] && { shown="$arg"; next=""; continue; }
      [ "$arg" = --revision ] && next=1
    done
    [[ "$shown" == drafts/*.json ]] \
      || fail bad-argument "approve-sop needs --revision with the review revision you showed the user (from review-sop), such as drafts/draft-003.json."
  fi
  resolve_company ""
  resolve_package "$given"
  [ "$mode" != frame ] || check_frame_out "$@"

  # Build if needed. While HQ Capture is open, an existing build is used as is so the running
  # app is not replaced underneath it.
  if app_is_open; then
    [ -x "$app_path/Contents/MacOS/$executable" ] || build_app
  else
    build_app
  fi

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
  record) shift; cmd_record "$@" ;;
  status) shift; cmd_status "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  run) shift; cmd_run "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  *) echo "usage: hq-record-process.sh {doctor|build [--force]|start [--company <slug>] [--record]|record|status|wait [--timeout <s>]|stop|run <mode> <package> [args]|resume <prompt>}" >&2; exit 2 ;;
esac
