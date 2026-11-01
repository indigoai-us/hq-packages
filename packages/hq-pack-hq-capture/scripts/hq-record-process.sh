#!/usr/bin/env bash
# hq-record-process — open and control HQ Capture for /record-process.
#
# HQ Capture ships inside the HQ desktop app (HQ.app/Contents/Helpers/HQ Capture.app) and
# needs macOS 26 or later. This script never builds or installs an app. Recording starts in
# the desktop app, so macOS holds HQ responsible for Screen Recording, camera and microphone:
# `start` asks HQ through the hq-desktop://record/<company> link, and HQ opens its permission
# window first when access is off, then the recorder. Status, wait, record and stop use the
# control folder the recorder shares with HQ. The agent modes that only read or write saved
# recordings run the bundled HQ Capture executable directly. Without the HQ desktop app, every
# subcommand that needs it prints the install link and starts nothing.
#
# Subcommands (each prints JSON on stdout):
#   doctor                        check this Mac has macOS 26 and the HQ desktop app with HQ Capture
#   start [--company <slug>] [--record]
#                                 ask HQ to open HQ Capture bound to a company's recordings folder;
#                                 refused with already-open while it is open, or busy while another
#                                 session is opening it. When HQ first needs a permission it prints
#                                 state waiting-permission (exit 0): HQ shows the steps, and the
#                                 recorder opens once access is on (follow it with wait). --record
#                                 then starts recording (as record) once the recorder is open
#   record                        start recording in the open HQ Capture, as if the user pressed
#                                 Start: writes start.request and waits for the app's answer.
#                                 Fails with start-blocked (and the blocker as reason) when the app
#                                 can't start, start-timeout when it doesn't answer, not-open,
#                                 already-recording, not-ready or other-company
#   status                        print status.json with the live state; after a save it adds
#                                 mediaIssues from the package and keeps the app's issue note.
#                                 Before the recorder opens it reports HQ's answer
#                                 (waiting-permission or refused). When HQ Capture is open for
#                                 another company it prints only
#                                 {"ok": true, "state": "busy-other-company"}; once that app has
#                                 exited it prints {"ok": true, "state": "none"}
#   wait [--timeout <seconds>]    block until the state is saved, failed, closed, lost or refused,
#                                 printing one line per change (with issue when the app sets
#                                 one) and the full status last; exit 3 when still open at timeout.
#                                 waiting-permission and relaunching (macOS Quit & Reopen after a
#                                 permission grant) are followed until the recorder reports
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
# These modes touch no camera, microphone or screen, so they run the bundled executable from
# the shell; transcription uses the on-device speech model on the saved narration file.
#
# Every subcommand except doctor uses the session's bound company and refuses
# a company, a package or a frame --out path inside another company.
#
# Environment overrides (used by tests):
#   HQ_ROOT              HQ root (default: nearest parent with companies/manifest.yaml)
#   HQ_DESKTOP_APP       the HQ desktop app to use, and the only one looked at (default: the
#                        installed HQ.app with bundle id ai.indigo.hq-sync-menubar, found in
#                        /Applications, ~/Applications, by Spotlight, or as the running app)
#   HQ_DESKTOP_OPEN      command run with the app path and the hq-desktop:// link to ask HQ to
#                        open the recorder (default: open -a)
#   HQ_DESKTOP_WAIT      seconds start waits for HQ to answer (default 30)
#   HQ_RECORDER_MACOS_VERSION  macOS version to assume, on any OS (tests only)
#   HQ_RECORDER_HOME     state dir holding the control folder `active` (default:
#                        ~/Library/Application Support/HQ Capture, the folder HQ uses)
#   HQ_RECORDER_START_WAIT seconds start waits for another start to finish (default 5)
#   HQ_RECORDER_STOP_WAIT  seconds stop waits for the app to act on a stop (default 20)
#   HQ_RECORDER_PROCESS_NAME  process name a live HQ Capture has (default: HQ Capture, or
#                        LocalScreenRecorder for a recorder the standalone app opened; tests only)
#   HQ_RECORDER_RELAUNCH_WAIT seconds a relaunching status counts as open after its app has
#                        quit, while macOS reopens it (default 30)
#   HQ_RECORDER_TAKEOVER_PAUSE seconds to pause between finding a stale lock and taking it over
#                        (tests only)
set -euo pipefail

state_dir="${HQ_RECORDER_HOME:-$HOME/Library/Application Support/HQ Capture}"
control_dir="$state_dir/active"
status_file="$control_dir/status.json"
launch_file="$control_dir/launch.json"
start_lock="$state_dir/.start.lock"
held_locks=()
refusal_code=1

# The HQ desktop app (macOS 26 and later) ships HQ Capture inside it.
desktop_bundle_id="ai.indigo.hq-sync-menubar"
capture_relpath="Contents/Helpers/HQ Capture.app/Contents/MacOS/HQ Capture"
# Canonical install links: the install page, and the direct macOS download.
install_page="https://hqforwork.com/install"
install_dmg="https://github.com/indigoai-us/hq-desktop-app/releases/latest/download/HQ.dmg"

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

# Prints the bundle id in the Info.plist of the app at $1, or nothing.
bundle_id_of() {
  python3 -I -c '
import plistlib, sys
try:
    print(plistlib.load(open(sys.argv[1] + "/Contents/Info.plist", "rb")).get("CFBundleIdentifier", ""))
except Exception:
    pass' "$1" 2>/dev/null || true
}

# Candidate HQ desktop apps, one per line, best first. HQ_DESKTOP_APP, when set, is the only one.
desktop_candidates() {
  if [ -n "${HQ_DESKTOP_APP+set}" ]; then
    printf '%s\n' "$HQ_DESKTOP_APP"
    return
  fi
  {
    printf '%s\n' "/Applications/HQ.app" "$HOME/Applications/HQ.app"
    if command -v mdfind >/dev/null 2>&1; then
      mdfind "kMDItemCFBundleIdentifier == '$desktop_bundle_id'" 2>/dev/null || true
    fi
    # The running app, wherever it was opened from.
    ps -axo comm= 2>/dev/null | sed -n 's#^\(/.*\.app\)/Contents/MacOS/hq-sync-menubar$#\1#p' || true
  } | awk 'NF && !seen[$0]++'
}

# Sets desktop_app to the HQ desktop app, preferring one that carries HQ Capture. Returns 1
# when none is installed.
find_desktop_app() {
  local candidate first=""
  desktop_app=""
  while IFS= read -r candidate; do
    [ -d "$candidate" ] && [ "$(bundle_id_of "$candidate")" = "$desktop_bundle_id" ] || continue
    [ -n "$first" ] || first="$candidate"
    if [ -x "$candidate/$capture_relpath" ]; then desktop_app="$candidate"; return 0; fi
  done < <(desktop_candidates)
  desktop_app="$first"
  [ -n "$desktop_app" ]
}

install_message() {
  printf '%s' "Recording needs the HQ desktop app on macOS 26 or later. Install it from $install_page (direct download for Mac: $install_dmg), open it once, then run /record-process again."
}

# Sets host_os and host_version (HQ_RECORDER_MACOS_VERSION stands in for both in tests).
host_macos() {
  if [ -n "${HQ_RECORDER_MACOS_VERSION:-}" ]; then
    host_os=Darwin host_version="$HQ_RECORDER_MACOS_VERSION"
  else
    host_os="$(uname -s)" host_version=""
    [ "$host_os" != Darwin ] || host_version="$(sw_vers -productVersion 2>/dev/null || true)"
  fi
}

# Checks this Mac can record through HQ and sets desktop_app and capture_exe. Refuses, starting
# nothing, when the desktop app or its HQ Capture is missing, or below macOS 26.
require_desktop() {
  local ver
  host_macos
  if [ "$host_os" != Darwin ]; then
    json ok false error needs-macos message "Recording needs a Mac with macOS 26 or later and the HQ desktop app." install "$install_page"
    exit "$refusal_code"
  fi
  ver="${host_version:-0}"
  if ! [[ "${ver%%.*}" =~ ^[0-9]+$ ]] || [ "${ver%%.*}" -lt 26 ]; then
    json ok false error macos-too-old message "Recording needs macOS 26 or later; this Mac has macOS $ver. Upgrade macOS, then install the HQ desktop app from $install_page." install "$install_page"
    exit "$refusal_code"
  fi
  if ! find_desktop_app; then
    json ok false error needs-desktop-app message "$(install_message)" install "$install_page" download "$install_dmg"
    exit "$refusal_code"
  fi
  capture_exe="$desktop_app/$capture_relpath"
  if [ ! -x "$capture_exe" ]; then
    json ok false error desktop-app-outdated app "$desktop_app" install "$install_page" download "$install_dmg" \
      message "The HQ desktop app at $desktop_app doesn't include HQ Capture yet. Update it (HQ menu, Check for updates) or reinstall it from $install_page, then run /record-process again."
    exit "$refusal_code"
  fi
}

# Prints {"state", "missing", "reason", "message", "age"} from HQ's launch note for the bound
# company, or nothing when there is none (or it is for another company).
launch_note() {
  python3 -I -c '
import json, os, sys, time
try:
    n = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(n, dict) or n.get("company") != sys.argv[2]:
    sys.exit(0)
age = int(time.time() - os.stat(sys.argv[1]).st_mtime)
print(json.dumps({"state": n.get("state"), "missing": n.get("missing") or [], "reason": n.get("reason"),
                  "message": n.get("message"), "age": age}))' "$launch_file" "$company" 2>/dev/null || true
}

# HQ's answer before the recorder has written a status: waiting-permission, opening, refused, or
# nothing. A waiting note older than five minutes (HQ forgets the attempt then) counts as none.
launch_state() {
  local note
  note="$(launch_note)"
  [ -n "$note" ] || return 0
  python3 -I -c '
import json, sys
n = json.loads(sys.argv[1])
s = n.get("state")
if s in ("waiting-permission", "opening") and n.get("age", 0) > 300: s = ""
if s == "open": s = "opening"
print(s or "")' "$note"
}

print_launch() {
  python3 -I -c '
import json, sys
n = json.loads(sys.argv[1]); state = sys.argv[2]
out = {"ok": state != "refused", "state": state, "company": sys.argv[3]}
if state == "waiting-permission":
    out["missing"] = n.get("missing") or []
    out["message"] = ("HQ is showing the steps to turn on " + (", ".join(m.replace("_", " ") for m in out["missing"]) or "access")
                      + ". HQ Capture opens once that is done. Run wait to follow it.")
elif state == "refused":
    out["error"] = "desktop-refused"
    out["reason"] = n.get("reason")
    out["message"] = n.get("message") or "HQ did not open HQ Capture."
print(json.dumps(out))' "$(launch_note)" "$1" "$company"
}

# Asks the HQ desktop app to open the recorder for the bound company.
ask_desktop_to_record() {
  local opener="${HQ_DESKTOP_OPEN:-open -a}"
  # shellcheck disable=SC2086
  $opener "$desktop_app" "hq-desktop://record/$company" >/dev/null 2>&1
}

# Prints a JSON string literal for $1. doctor uses this so it works without python3.
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"
  printf '"%s"' "$s"
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

release_locks() {
  local dir
  for dir in ${held_locks[@]+"${held_locks[@]}"}; do release_lock "$dir"; done
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

# Builds its JSON in bash, so the fix line still prints on a Mac without python3.
cmd_doctor() {
  local os ver="" macos26=false app="" capture=false all=true fix=""
  host_macos
  os="$host_os"
  if [ "$os" = Darwin ]; then
    ver="$host_version"
    [[ "${ver%%.*}" =~ ^[0-9]+$ ]] && [ "${ver%%.*}" -ge 26 ] && macos26=true
    if command -v python3 >/dev/null 2>&1 && find_desktop_app; then
      app="$desktop_app"
      [ -x "$app/$capture_relpath" ] && capture=true
    fi
  fi
  if [ "$os" != Darwin ] || [ "$macos26" != true ]; then
    all=false; fix="Recording needs a Mac with macOS 26 or later and the HQ desktop app ($install_page)."
  elif [ -z "$app" ]; then
    all=false; fix="$(install_message)"
  elif [ "$capture" != true ]; then
    all=false; fix="Update the HQ desktop app at $app (HQ menu, Check for updates) or reinstall it from $install_page."
  fi
  printf '{"ok": %s, "macos": %s, "macos_detail": %s, "macos_26_or_later": %s, "macos_26_or_later_detail": %s, "hq_desktop_app": %s, "hq_desktop_app_detail": %s, "hq_capture": %s, "hq_capture_detail": %s, "install": %s' \
    "$all" "$([ "$os" = Darwin ] && echo true || echo false)" "$(json_string "$os")" "$macos26" "$(json_string "${ver:-unknown}")" \
    "$([ -n "$app" ] && echo true || echo false)" "$(json_string "${app:-missing}")" "$capture" \
    "$(json_string "$([ "$capture" = true ] && printf '%s' "$app/$capture_relpath" || echo missing)")" "$(json_string "$install_page")"
  [ -z "$fix" ] || printf ', "fix": %s' "$(json_string "$fix")"
  printf '}\n'
  [ "$all" = true ]
}

# True when $1 is a running HQ Capture process. Checking the process name as well as that the
# pid is alive means a pid that macOS has since given to another program does not count.
is_app_process() {
  local pid="$1" comm
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  comm="$(ps -p "$pid" -o comm= 2>/dev/null)" || return 1
  comm="${comm%"${comm##*[![:space:]]}"}"
  comm="${comm##*/}"
  if [ -n "${HQ_RECORDER_PROCESS_NAME:-}" ]; then
    [ "$comm" = "$HQ_RECORDER_PROCESS_NAME" ]
  else
    [ "$comm" = "HQ Capture" ] || [ "$comm" = LocalScreenRecorder ]
  fi
}

status_pid() {
  python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1])).get("pid", ""))' "$status_file" 2>/dev/null || true
}

# Prints the app's state, mapping a vanished process to "lost".
current_state() {
  if [ ! -f "$status_file" ]; then
    local launch
    launch="$(launch_state)"
    echo "${launch:-none}"
    return
  fi
  local reading state pid
  reading="$(read_status_state)" || { echo unreadable; return; }
  state="${reading%%$'\t'*}" pid="${reading#*$'\t'}"
  case "$state" in
    closed|saved|failed) echo "$state" ;;
    # The app quit for macOS Quit & Reopen after a Screen Recording grant. It stays relaunching
    # while that app is still quitting and for a short wait after, while macOS reopens it and the
    # reopened app writes its own status. If none does, it was a plain quit: closed.
    relaunching)
      if is_app_process "$pid" || [ "$(status_age)" -lt "${HQ_RECORDER_RELAUNCH_WAIT:-30}" ]; then
        echo relaunching
      else
        echo closed
      fi ;;
    *) if is_app_process "$pid"; then echo "$state"; else echo lost; fi ;;
  esac
}

# read_status <python>: runs the python code on status.json and prints its output. A writer that
# does not replace the file atomically can leave it empty or half written for a moment, so a
# failed read is retried briefly; returns 1 when it is still unreadable (no reading this time).
read_status() {
  local attempt reading
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if reading="$(python3 -I -c "$1" "$status_file" 2>/dev/null)"; then
      printf '%s\n' "$reading"
      return 0
    fi
    [ "$attempt" = 10 ] || sleep 0.05
  done
  return 1
}

# Prints "<state><TAB><pid>" from one read of status.json; returns 1 when it is unreadable. A
# state that is not a non-empty string is unreadable too.
read_status_state() {
  read_status '
import json, sys
s = json.load(open(sys.argv[1]))
state = s.get("state") if isinstance(s, dict) else None
if not isinstance(state, str) or not state: sys.exit(1)
pid = s.get("pid")
print("%s\t%s" % (state, pid if isinstance(pid, int) else ""))'
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

# True when HQ Capture's status belongs to a company other than the bound one. A status
# with no company counts as another company's. An unreadable status is not known to be
# another company's: false, and current_state reports it as unreadable.
status_for_other_company() {
  [ -f "$status_file" ] || return 1
  local owner
  owner="$(read_status '
import json, sys
s = json.load(open(sys.argv[1]))
if not isinstance(s, dict): sys.exit(1)
c = s.get("company")
print(c if isinstance(c, str) else "")')" || return 1
  [ "$owner" != "$company" ]
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
  if [ "$state" = unreadable ]; then
    json ok false error status-unreadable message "HQ Capture's status file can't be read right now. Run status again in a moment."
    return
  fi
  case "$state" in waiting-permission|opening|refused) print_launch "$state"; return ;; esac
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
  require_desktop
  resolve_company "$requested"

  acquire_start_lock
  if app_is_open; then
    fail already-open "HQ Capture is already open (state: $(current_state)). Stop it before starting another."
  fi

  mkdir -p "$destination" 2>/dev/null || fail destination-unwritable "Can't create $destination."
  [ -w "$destination" ] || fail destination-unwritable "Can't write to $destination."

  rm -rf "$control_dir"; mkdir -p "$control_dir"
  ask_desktop_to_record || fail launch-failed "macOS could not open the HQ desktop app at $desktop_app."

  # HQ answers in launch.json; the recorder reports in status.json once it is open.
  local limit="${HQ_DESKTOP_WAIT:-30}" launch=""
  for _ in $(seq 1 $((limit * 4))); do
    [ -f "$status_file" ] && break
    launch="$(launch_state)"
    case "$launch" in
      waiting-permission) release_lock "$start_lock"; print_launch waiting-permission; return 0 ;;
      refused) release_lock "$start_lock"; print_launch refused; exit 1 ;;
    esac
    sleep 0.25
  done
  [ -f "$status_file" ] || fail no-answer "HQ didn't open HQ Capture within $limit seconds. Open the HQ desktop app, check it is signed in, then run /record-process again."
  local opened_for
  opened_for="$(python3 -I -c 'import json,os,sys; d=json.load(open(sys.argv[1])).get("destination") or ""; print(os.path.realpath(d) if d else "")' "$status_file" 2>/dev/null || true)"
  if [ -n "$opened_for" ] && [ "$opened_for" != "$(realpath_of "$destination")" ]; then
    : >"$control_dir/stop.request"
    fail destination-mismatch "HQ opened HQ Capture for $opened_for, not this HQ's $destination. The HQ desktop app uses a different HQ folder; point it at this one in HQ Settings."
  fi
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
  mkdir -p "$state_dir"
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
  local limit="${HQ_RECORDER_RECORD_WAIT:-20}"
  rm -f "$accepted"
  printf '%s\n' "$company" >"$request.$$"
  mv "$request.$$" "$request"
  release_lock "$start_lock"
  for _ in $(seq 1 $((limit * 4))); do
    [ -e "$request" ] || break
    sleep 0.25
  done
  # Withdraw a request the app has not accepted. Removing it fails only when the app renamed it
  # to start.accepted first, and then the app is starting and its answer is still to come.
  if python3 -I -c 'import os,sys; os.remove(sys.argv[1])' "$request" 2>/dev/null; then
    fail start-timeout "HQ Capture did not answer the start request within $limit seconds. The request was withdrawn."
  fi
  for _ in $(seq 1 $((limit * 4))); do
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
  if [ ! -f "$status_file" ] && [ -z "$(launch_state)" ]; then
    fail not-open "HQ Capture has not been opened. Run start first."
  fi
  if [ -f "$status_file" ] && status_for_other_company && ! app_is_open; then
    fail not-open "HQ Capture has not been opened. Run start first."
  fi
  local deadline=$(( $(date +%s) + limit )) last="" now state line
  while :; do
    # Checked on every pass: another company's session may start HQ Capture while this waits.
    if open_for_other_company; then busy_other_company; return 0; fi
    if status_for_other_company; then json ok true state none; return 0; fi
    state="$(current_state)"
    case "$state" in
      waiting-permission|opening)
        line="$(json event state state "$state")"
        if [ "$line" != "$last" ]; then printf '%s\n' "$line"; last="$line"; fi
        if [ "$(date +%s)" -ge "$deadline" ]; then print_status; exit 3; fi
        sleep 1; continue ;;
      refused) print_status; return 0 ;;
      none) print_status; return 0 ;;
      unreadable)
        if [ "$(date +%s)" -ge "$deadline" ]; then print_status; exit 3; fi
        sleep 0.2; continue ;;
    esac
    line="$(python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1]))
if not isinstance(s, dict) or not sys.argv[2]: sys.exit(1)
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
  local limit="${HQ_RECORDER_STOP_WAIT:-20}" state
  for _ in $(seq 1 $((limit * 4))); do
    # An unreadable status (a write in progress) is no reading: keep waiting.
    [ "$(current_state)" = unreadable ] || app_is_open || break
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
  require_desktop
  resolve_company ""
  resolve_package "$given"
  [ "$mode" != frame ] || check_frame_out "$@"

  local extra=()
  [ "$mode" = sync-package ] && extra=(--hq-root "$root")
  set +e
  "$capture_exe" "--$mode" "$package" "$@" ${extra[@]+"${extra[@]}"}
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
  start) shift; cmd_start "$@" ;;
  record) shift; cmd_record "$@" ;;
  status) shift; cmd_status "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  run) shift; cmd_run "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  *) echo "usage: hq-record-process.sh {doctor|start [--company <slug>] [--record]|record|status|wait [--timeout <s>]|stop|run <mode> <package> [args]|resume <prompt>}" >&2; exit 2 ;;
esac
