#!/usr/bin/env bash
# Launcher tests for hq-record-process.sh. Safe on any OS: the compiler is replaced by a
# stub that writes a fake HQ Capture.app whose executable echoes its arguments, and the
# opener is replaced by a stub that speaks the same file control channel as the real app
# (status.json, start.request and stop.request). The real macOS build and launch are covered by
# tests/e2e-macos.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp="$(mktemp -d)"
cleanup() {
  [ -f "$tmp/apps/stub.pid" ] && kill "$(cat "$tmp/apps/stub.pid")" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# A copy of the pack, so the test can change app/SOURCE.
mkdir -p "$tmp/pack"
cp -R "$here/../app" "$here/../scripts" "$tmp/pack/"
R="$tmp/pack/scripts/hq-record-process.sh"

# Fake HQ root with two companies. The CLI shim supplies the current session company.
hq="$tmp/hq"
mkdir -p "$hq/companies/acme" "$hq/companies/other" "$hq/core/scripts" "$tmp/bin"
printf 'companies:\n  acme:\n    name: Acme\n  other:\n    name: Other\n' >"$hq/companies/manifest.yaml"
cat >"$hq/core/scripts/hq-session.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "get company_slug" ] && cat "$(dirname "$0")/session-company"
EOF
chmod +x "$hq/core/scripts/hq-session.sh"
cat >"$tmp/bin/hq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HQ_VERIFY_HQ_LOG"
if [ "$*" = "core hq-session get company_slug" ]; then
  [ "${HQ_VERIFY_HQ_EXIT:-0}" -eq 0 ] || exit "$HQ_VERIFY_HQ_EXIT"
  printf '%s' "${HQ_VERIFY_SESSION_COMPANY:-}"
fi
EOF
chmod +x "$tmp/bin/hq"
export HQ_VERIFY_HQ_LOG="$tmp/hq.log" HQ_VERIFY_SESSION_COMPANY="" HQ_VERIFY_HQ_EXIT=0
session() {
  HQ_VERIFY_SESSION_COMPANY="$1"
  export HQ_VERIFY_SESSION_COMPANY
  printf '%s' "$1" >"$hq/core/scripts/session-company"
}

# Stub compiler: writes an app whose executable prints its arguments as JSON and exits
# with $STUB_EXIT (default 0). Each build appends a line to builds.log.
cat >"$tmp/stub-compile.sh" <<'EOF'
#!/usr/bin/env bash
app="$1"
mkdir -p "$app/Contents/MacOS"
cat >"$app/Contents/MacOS/LocalScreenRecorder" <<'BIN'
#!/usr/bin/env bash
python3 -I -c 'import json,sys; print(json.dumps({"argv": sys.argv[1:]}))' "$@"
exit "${STUB_EXIT:-0}"
BIN
chmod +x "$app/Contents/MacOS/LocalScreenRecorder"
echo built >>"$(dirname "$0")/builds.log"
EOF
chmod +x "$tmp/stub-compile.sh"

# Stub opener: records the app's argv, writes awaiting-start, switches to recording when
# go.record appears, and on stop.request saves (if recording) or closes. At save, media.issue
# makes the package manifest list a short narration file and app.issue makes the status carry
# the app's note about it.
cat >"$tmp/stub-open.sh" <<'EOF'
#!/usr/bin/env bash
app="$1"; shift; [ "$1" = --args ] && shift
printf '%s\n' "$@" >"$app.argv"
echo launched >>"$(dirname "$0")/launches.log"
python3 -I - "$(dirname "$0")/go.record" "$@" <<'PY' >/dev/null 2>&1 &
import json, os, sys, time
go = sys.argv[1]
flags = os.path.dirname(go)
args = dict(zip(sys.argv[2::2], sys.argv[3::2]))
ctl = args["--hq-control"]
def write(state, **extra):
    s = {"schema": 1, "state": state, "company": args["--company"],
         "destination": args["--destination"], "pid": os.getpid(),
         "updatedAt": "2026-01-01T00:00:00Z"}
    s.update(extra)
    tmp = os.path.join(ctl, ".status.tmp")
    with open(tmp, "w") as f: json.dump(s, f)
    os.replace(tmp, os.path.join(ctl, "status.json"))
write("awaiting-start")
recording = False
stop_request = os.path.join(ctl, "stop.request")
user_stop = os.path.join(flags, "user.stop")
# ignore.stop makes the stub ignore stop requests; finalize.stop makes it answer one by
# showing finalizing and staying there.
ignore_stop = os.path.join(flags, "ignore.stop")
finalize_stop = os.path.join(flags, "finalize.stop")
def stop_asked():
    return os.path.exists(stop_request) and not os.path.exists(ignore_stop)
# start.request is HQ asking the app to press Start; it holds the requesting company. Like the
# real app, the stub accepts it by renaming it to start.accepted, writes its answer to
# status.json, then removes start.accepted. The company it read is logged to start.company.
# blocked.start makes it answer the way the app does when a blocker is showing (it stays
# awaiting start and says why); slow.start makes it take 2 seconds to start; ignore.start makes
# it leave the request untouched, like an app that never reads it.
start_request = os.path.join(ctl, "start.request")
start_accepted = os.path.join(ctl, "start.accepted")
blocked_start = os.path.join(flags, "blocked.start")
slow_start = os.path.join(flags, "slow.start")
ignore_start = os.path.join(flags, "ignore.start")
def accept_start():
    if os.path.exists(ignore_start): return None
    try:
        os.rename(start_request, start_accepted)
    except FileNotFoundError:
        return None
    asked_by = open(start_accepted).read().strip()
    with open(os.path.join(flags, "start.company"), "w") as f: f.write(asked_by)
    return asked_by
while not stop_asked() and not (recording and os.path.exists(user_stop)):
    asked_by = accept_start() if not recording else None
    if asked_by is not None:
        if asked_by != args["--company"]:
            write("awaiting-start", reason="start-company-mismatch")
        elif os.path.exists(blocked_start):
            write("awaiting-start", reason="screen-recording-permission")
        else:
            if os.path.exists(slow_start): time.sleep(2)
            recording = True
            write("recording", paused=False, durationSeconds=1.5)
        os.remove(start_accepted)
    elif not recording and os.path.exists(go):
        recording = True
        write("recording", paused=False, durationSeconds=1.5)
    time.sleep(0.05)
if stop_asked() and os.path.exists(finalize_stop):
    os.remove(stop_request)
    write("finalizing")
    while True:
        time.sleep(0.05)
by_user = not os.path.exists(stop_request)
if not by_user:
    os.remove(stop_request)
if recording:
    pkg = os.path.join(args["--destination"], "demo.hqrec")
    os.makedirs(pkg, exist_ok=True)
    note = ("The narration file is 9.0 seconds long but the recording has 12.0 seconds of it, "
            "so it may not line up. The original files are kept.")
    extra = {}
    if os.path.exists(os.path.join(flags, "media.issue")):
        with open(os.path.join(pkg, "manifest.json"), "w") as f:
            json.dump({"schema": 1, "mediaIssues": [{"kind": "microphone", "relativePath": "tracks/microphone-001.m4a",
                       "timelineSeconds": 12.0, "fileSeconds": 9.0, "message": note}]}, f)
    if os.path.exists(os.path.join(flags, "app.issue")):
        extra["issue"] = note
    rel = "companies/%s/recordings/demo.hqrec" % args["--company"]
    prompt = ("Continue my HQ Capture recording for %s at %s: show me what was recorded, then trim, "
              "place the camera, export the video and draft the step-by-step guide." % (args["--company"], pkg))
    write("saved", recording=rel, durationSeconds=2.0, resumePrompt=prompt,
          reason="user-stopped" if by_user else "stop-requested", **extra)
else:
    write("closed")
# Stopped from the window (user.stop): like the real app, it stays open showing the saved
# recording until a stop request asks it to quit, and quitting keeps the saved status.
if by_user:
    while not os.path.exists(stop_request):
        time.sleep(0.05)
    os.remove(stop_request)
PY
echo $! >"$(dirname "$app")/stub.pid"
EOF
chmod +x "$tmp/stub-open.sh"

mkdir -p "$tmp/apps" "$tmp/legacy/HQ Recorder.app/Contents" "$tmp/state/LocalScreenRecorder.app/Contents"
touch "$tmp/legacy/build.stamp" "$tmp/legacy/keep.txt"
export HQ_ROOT="$hq"
export PATH="$tmp/bin:$PATH"
export HQ_RECORDER_HOME="$tmp/state"
export HQ_RECORDER_APP="$tmp/apps/HQ Capture.app"
export HQ_RECORDER_OPEN="$tmp/stub-open.sh"
export HQ_RECORDER_COMPILE="$tmp/stub-compile.sh"
export HQ_RECORDER_LEGACY_HOME="$tmp/legacy"
# The stub app is a python3 process, so the launcher's process-name check looks for python3's
# name here instead of LocalScreenRecorder.
HQ_RECORDER_PROCESS_NAME="$(python3 -I -c 'import os,subprocess; c=subprocess.check_output(["ps","-p",str(os.getpid()),"-o","comm="]).decode().strip(); print(os.path.basename(c))')"
export HQ_RECORDER_PROCESS_NAME
launches() { [ -f "$tmp/launches.log" ] && wc -l <"$tmp/launches.log" | tr -d ' ' || echo 0; }
builds() { [ -f "$tmp/builds.log" ] && wc -l <"$tmp/builds.log" | tr -d ' ' || echo 0; }

pass=0
check() { # check <description> <python expression over j> <json>
  if python3 -I -c 'import json,sys; j=json.loads(sys.argv[2]); sys.exit(0 if eval(sys.argv[1]) else 1)' "$2" "$3"; then
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n  got: %s\n' "$1" "$3" >&2; exit 1
  fi
}
expect() { # expect <description> <got> <want>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else printf 'FAIL: %s: expected %s, got %s\n' "$1" "$3" "$2" >&2; exit 1; fi
}
run() { bash "$R" "$@" 2>/dev/null || true; }
code() { set +e; bash "$R" "$@" >/dev/null 2>&1; local c=$?; set -e; echo "$c"; }
last() { tail -n 1 <<<"$1"; }

# Company refusals.
session ""
check "no company in session is refused" 'j["ok"] is False and j["error"]=="no-company"' "$(run start)"
session "personal"
check "personal session is refused" 'j["error"]=="no-company"' "$(run start)"
check "--company without a value is refused" 'j["error"]=="bad-argument"' "$(run start --company)"
check "--company with no bound company is refused" 'j["ok"] is False and j["error"]=="no-company"' "$(run start --company acme)"
expect "--company with no bound company exits 1" "$(code start --company acme)" "1"
check "status with no bound company is refused" 'j["error"]=="no-company"' "$(run status)"
check "wait with no bound company is refused" 'j["error"]=="no-company"' "$(run wait --timeout 1)"
check "stop with no bound company is refused" 'j["error"]=="no-company"' "$(run stop)"
check "record with no bound company is refused" 'j["error"]=="no-company"' "$(run record)"
session "ghost"
check "unknown company is refused" 'j["error"]=="unknown-company"' "$(run start)"
session "../acme"
check "invalid company name is refused" 'j["error"]=="bad-company"' "$(run start)"
[ ! -e "$HQ_RECORDER_HOME/active/status.json" ] && pass=$((pass + 1)) \
  || { echo "FAIL: a refused start should not create status.json" >&2; exit 1; }
session "acme"
check "status before any start is none" 'j["state"]=="none"' "$(run status)"
grep -q '^core hq-session get company_slug$' "$HQ_VERIFY_HQ_LOG" && pass=$((pass + 1)) \
  || { echo "FAIL: company binding must use hq core hq-session" >&2; exit 1; }
session "acme"
HQ_VERIFY_HQ_EXIT=7
check "CLI failure does not use a shell-script fallback" 'j["error"]=="no-company"' "$(run start)"
HQ_VERIFY_HQ_EXIT=0
session "acme"
check "wait before any start is refused" 'j["error"]=="not-open"' "$(run wait --timeout 1)"
check "record before any start is refused" 'j["ok"] is False and j["error"]=="not-open"' "$(run record)"
expect "record before any start exits 1" "$(code record)" "1"
check "a company other than the bound one is refused" 'j["error"]=="company-mismatch"' "$(run start --company other)"
expect "nothing was built for a refused start" "$(builds)" "0"

# Start builds once, binds the company and removes the 0.1.0 app.
out="$(run start)"
check "start opens HQ Capture awaiting user start" \
  'j["ok"] and j["state"]=="awaiting-start" and j["company"]=="acme" and j["destination"].endswith("/companies/acme/recordings")' "$out"
expect "first start builds" "$(builds)" "1"
[ -x "$HQ_RECORDER_APP/Contents/MacOS/LocalScreenRecorder" ] && pass=$((pass + 1)) \
  || { echo "FAIL: built app has no LocalScreenRecorder executable" >&2; exit 1; }
[ ! -e "$tmp/legacy/HQ Recorder.app" ] && [ ! -e "$tmp/state/LocalScreenRecorder.app" ] && [ ! -e "$tmp/legacy/build.stamp" ] \
  && [ -e "$tmp/legacy/keep.txt" ] && pass=$((pass + 1)) \
  || { echo "FAIL: old app bundles should be removed and nothing else" >&2; exit 1; }
[ -d "$hq/companies/acme/recordings" ] && [ -z "$(ls -A "$hq/companies/acme/recordings")" ] && pass=$((pass + 1)) \
  || { echo "FAIL: destination should exist and be empty" >&2; exit 1; }
argv="$(cat "$HQ_RECORDER_APP.argv")"
grep -qx -- "--hq-control" <<<"$argv" && grep -qx -- "--company" <<<"$argv" && grep -qx "acme" <<<"$argv" \
  && grep -q '/companies/acme/recordings$' <<<"$argv" && pass=$((pass + 1)) \
  || { echo "FAIL: app did not receive the control folder, company and destination" >&2; exit 1; }

check "a second start is refused while open" 'j["error"]=="already-open"' "$(run start)"
check "status reports the open app" 'j["state"]=="awaiting-start" and j["company"]=="acme"' "$(run status)"

# Another company's session sees only that HQ Capture is busy, and can't stop it.
session "other"
check "status in another company is redacted" 'j=={"ok": True, "state": "busy-other-company"}' "$(run status)"
out="$(run wait --timeout 1)"
check "wait in another company prints only the redacted status" 'j=={"ok": True, "state": "busy-other-company"}' "$out"
expect "wait in another company prints one line" "$(wc -l <<<"$out" | tr -d ' ')" "1"
expect "wait in another company exits 0" "$(code wait --timeout 1)" "0"
check "stop in another company is refused" 'j["ok"] is False and j["error"]=="other-company"' "$(run stop)"
expect "stop in another company exits 1" "$(code stop)" "1"
session "acme"
check "the app is still open after another company's stop" 'j["state"]=="awaiting-start" and j["company"]=="acme"' "$(run status)"

# wait: argument checks, timeout while open, state changes, save.
check "wait rejects a bad timeout" 'j["error"]=="bad-argument"' "$(run wait --timeout abc)"
check "wait rejects a zero timeout" 'j["error"]=="bad-argument"' "$(run wait --timeout 0)"
check "wait rejects an unknown argument" 'j["error"]=="bad-argument"' "$(run wait --forever)"
expect "wait exits 3 when still open at the timeout" "$(code wait --timeout 1)" "3"
out="$(run wait --timeout 1)"
check "wait prints the awaiting-start state first" 'j["event"]=="state" and j["state"]=="awaiting-start"' "$(head -n 1 <<<"$out")"
check "wait ends with the full status at the timeout" 'j["ok"] and j["state"]=="awaiting-start"' "$(last "$out")"
touch "$tmp/go.record"
sleep 0.5
out="$(run wait --timeout 1)"
check "wait reports recording with pause and duration" \
  'j["state"]=="recording" and j["paused"] is False and j["durationSeconds"]==1.5' "$(head -n 1 <<<"$out")"
check "stop saves the recording" 'j["state"]=="saved" and j["recording"]=="companies/acme/recordings/demo.hqrec"' "$(run stop)"
check "a clean save has no issue and no mediaIssues" '"issue" not in j and "mediaIssues" not in j' "$(run status)"
out="$(run wait --timeout 5)"
expect "wait exits 0 once saved" "$(code wait --timeout 5)" "0"
check "wait returns the resume prompt after save" \
  'j["state"]=="saved" and j["resumePrompt"].startswith("Continue my HQ Capture recording for acme at /")' "$(last "$out")"
check "stop when saved is a no-op" 'j["state"]=="saved"' "$(run stop)"
rm -f "$tmp/go.record"
prompt="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["resumePrompt"])' "$(last "$out")")"

# Media issues: after a save, status and wait show the app's note and the package's mediaIssues.
touch "$tmp/media.issue" "$tmp/app.issue"
check "start opens for a second recording" 'j["state"]=="awaiting-start"' "$(run start)"
touch "$tmp/go.record"
sleep 0.5
check "stop saves the second recording" 'j["state"]=="saved"' "$(run stop)"
out="$(run wait --timeout 5)"
check "wait's saved line carries the app's issue note" \
  'j["event"]=="state" and j["state"]=="saved" and j["issue"].startswith("The narration file is 9.0 seconds long")' "$(head -n 1 <<<"$out")"
check "wait ends with the mediaIssues from the package" \
  'j["state"]=="saved" and j["mediaIssues"][0]["kind"]=="microphone" and j["mediaIssues"][0]["fileSeconds"]==9.0 and j["issue"]==j["mediaIssues"][0]["message"]' "$(last "$out")"
check "status lists each media issue with its file and message" \
  'j["mediaIssues"][0]["relativePath"]=="tracks/microphone-001.m4a" and "may not line up" in j["mediaIssues"][0]["message"]' "$(run status)"
python3 -I -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s.pop("issue"); json.dump(s, open(p, "w"))' "$HQ_RECORDER_HOME/active/status.json"
check "status uses the first media issue as the note when the app gave none" \
  'j["issue"].startswith("The narration file is 9.0 seconds long") and len(j["mediaIssues"])==1' "$(run status)"
printf 'not json' >"$hq/companies/acme/recordings/demo.hqrec/manifest.json"
check "an unreadable manifest leaves status working without mediaIssues" 'j["ok"] and "mediaIssues" not in j' "$(run status)"
rm -f "$tmp/media.issue" "$tmp/app.issue" "$tmp/go.record" "$hq/companies/acme/recordings/demo.hqrec/manifest.json"

# record: HQ starts the recording itself instead of the user pressing Start.
ctl="$HQ_RECORDER_HOME/active"
check "record when HQ Capture has quit is refused" 'j["error"]=="not-open"' "$(run record)"
check "record rejects an unknown argument" 'j["error"]=="bad-argument"' "$(run record --now)"
check "start opens for a recording HQ starts" 'j["state"]=="awaiting-start"' "$(run start)"
session "other"
check "record in another company is refused" 'j["ok"] is False and j["error"]=="other-company"' "$(run record)"
[ ! -e "$ctl/start.request" ] && pass=$((pass + 1)) \
  || { echo "FAIL: another company's record should not ask the app to start" >&2; exit 1; }
session "acme"
touch "$tmp/blocked.start"
out="$(run record)"
check "record reports why the app could not start" \
  'j["ok"] is False and j["error"]=="start-blocked" and j["reason"]=="screen-recording-permission"' "$out"
expect "a blocked record exits 1" "$(code record)" "1"
check "a blocked record leaves the app awaiting start" 'j["state"]=="awaiting-start"' "$(run status)"
rm -f "$tmp/blocked.start"
touch "$tmp/ignore.start"
out="$(HQ_RECORDER_RECORD_WAIT=1 bash "$R" record 2>/dev/null || true)"
check "record times out when the app does not answer" 'j["ok"] is False and j["error"]=="start-timeout"' "$out"
[ ! -e "$ctl/start.request" ] && pass=$((pass + 1)) \
  || { echo "FAIL: a timed-out record should withdraw start.request" >&2; exit 1; }
rm -f "$tmp/ignore.start"
check "record starts the recording" 'j["ok"] and j["state"]=="recording" and j["paused"] is False' "$(run record)"
expect "the start request names the session's company" "$(cat "$tmp/start.company")" "acme"
[ ! -e "$ctl/start.request" ] && pass=$((pass + 1)) \
  || { echo "FAIL: the app should consume start.request" >&2; exit 1; }
check "record while recording is refused" 'j["ok"] is False and j["error"]=="already-recording"' "$(run record)"
check "stop saves the recording HQ started" 'j["state"]=="saved" and j["reason"]=="stop-requested"' "$(run stop)"
check "start opens for a slow start" 'j["state"]=="awaiting-start"' "$(run start)"
touch "$tmp/slow.start"
out="$(HQ_RECORDER_RECORD_WAIT=1 bash "$R" record 2>/dev/null || true)"
check "an accepted start that outlasts the wait is start-pending, not start-timeout" \
  'j["ok"] is False and j["error"]=="start-pending"' "$out"
sleep 2.5
check "the accepted start goes on to record" 'j["state"]=="recording"' "$(run status)"
rm -f "$tmp/slow.start"
check "stop saves the slow-start recording" 'j["state"]=="saved"' "$(run stop)"
out="$(run start --record)"
check "start --record opens HQ Capture and starts recording" 'j["ok"] and j["state"]=="recording"' "$out"
check "stop saves the start --record recording" 'j["state"]=="saved"' "$(run stop)"

# Rebuild only when the pack's app inputs change.
out="$(run start)"
check "start works again after a save" 'j["state"]=="awaiting-start"' "$out"
expect "an unchanged pack does not rebuild" "$(builds)" "1"
check "stop closes HQ Capture" 'j["state"]=="closed"' "$(run stop)"
printf 'local-screen-recorder 0000000000000000000000000000000000000000\n' >"$tmp/pack/app/SOURCE"
check "start after a SOURCE change opens" 'j["state"]=="awaiting-start"' "$(run start)"
expect "a SOURCE change rebuilds" "$(builds)" "2"
check "build refuses to replace the app while it is open" 'j["error"]=="already-open"' "$(run build --force)"
check "stop closes it" 'j["state"]=="closed"' "$(run stop)"
check "build reports a current build without rebuilding" 'j["ok"] and j["built"] is False' "$(run build)"
check "build --force rebuilds" 'j["ok"] and j["built"] is True' "$(run build --force)"
expect "build --force ran the compiler" "$(builds)" "3"

# A saved or failed app whose process is still running counts as open until it quits.
alive() { kill -0 "$(cat "$tmp/apps/stub.pid")" 2>/dev/null && echo yes || echo no; }
check "start opens for a recording stopped in the window" 'j["state"]=="awaiting-start"' "$(run start)"
touch "$tmp/go.record"; sleep 0.5; touch "$tmp/user.stop"
check "a recording stopped in the window is saved" 'j["state"]=="saved" and j["reason"]=="user-stopped"' "$(last "$(run wait --timeout 5)")"
expect "the app stays open after saving from the window" "$(alive)" "yes"
check "start refuses while the saved app is still open" 'j["ok"] is False and j["error"]=="already-open"' "$(run start)"
expect "start refuses a saved app that is still open with exit 1" "$(code start)" "1"
check "build refuses to replace a saved app that is still open" 'j["error"]=="already-open"' "$(run build --force)"
check "status still reports the saved recording" 'j["state"]=="saved" and j["resumePrompt"].startswith("Continue my HQ Capture")' "$(run status)"
check "stop closes the saved app and keeps the saved status" \
  'j["state"]=="saved" and j["recording"]=="companies/acme/recordings/demo.hqrec" and j["resumePrompt"].startswith("Continue my HQ Capture")' "$(run stop)"
expect "the saved app has quit after stop" "$(alive)" "no"
rm -f "$tmp/go.record" "$tmp/user.stop"
check "start works after stop closes the saved app" 'j["state"]=="awaiting-start"' "$(run start)"
check "stop closes the new app" 'j["state"]=="closed"' "$(run stop)"
# A failed app that is still open is treated the same way.
check "start opens for a failed recording" 'j["state"]=="awaiting-start"' "$(run start)"
touch "$tmp/go.record"; sleep 0.5; touch "$tmp/user.stop"
run wait --timeout 5 >/dev/null
python3 -I -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["state"]="failed"; json.dump(s, open(p, "w"))' "$HQ_RECORDER_HOME/active/status.json"
check "start refuses while the failed app is still open" 'j["error"]=="already-open"' "$(run start)"
check "stop closes the failed app and keeps the failed status" 'j["state"]=="failed"' "$(run stop)"
expect "the failed app has quit after stop" "$(alive)" "no"
rm -f "$tmp/go.record" "$tmp/user.stop"
# A saved app whose process is gone keeps today's behavior: status says saved and start opens.
check "start opens for a recording whose app then dies" 'j["state"]=="awaiting-start"' "$(run start)"
touch "$tmp/go.record"; sleep 0.5; touch "$tmp/user.stop"
run wait --timeout 5 >/dev/null
kill -9 "$(cat "$tmp/apps/stub.pid")"; sleep 0.2
rm -f "$tmp/go.record" "$tmp/user.stop"
check "a saved app that quit is still reported as saved" 'j["state"]=="saved"' "$(run status)"
check "stop on a saved app that quit is a no-op" 'j["state"]=="saved"' "$(run stop)"
check "start proceeds after a saved app quit" 'j["state"]=="awaiting-start"' "$(run start)"
check "stop closes it again" 'j["state"]=="closed"' "$(run stop)"
expect "none of this rebuilt the app" "$(builds)" "3"

# run: argument, company and package checks.
pkg="$hq/companies/acme/recordings/demo.hqrec"
mkdir -p "$hq/companies/other/recordings/theirs.hqrec" "$hq/companies/acme/recordings/notes"
ln -s "$hq/companies/other/recordings/theirs.hqrec" "$hq/companies/acme/recordings/link.hqrec"
check "run needs a mode and a package" 'j["error"]=="bad-argument"' "$(run run describe)"
expect "run refusals exit 3" "$(code run describe)" "3"
check "run rejects an unknown mode" 'j["error"]=="bad-mode"' "$(run run measure-sync "$pkg")"
check "run rejects a second mode in the arguments" 'j["error"]=="bad-argument"' "$(run run edit "$pkg" --sync-package)"
check "run rejects a company override" 'j["error"]=="bad-argument"' "$(run run describe "$pkg" --company other)"
check "run rejects a destination override" 'j["error"]=="bad-argument"' "$(run run describe "$pkg" --destination /tmp)"
check "run refuses another company's recording" 'j["error"]=="package-outside-company"' \
  "$(run run describe "$hq/companies/other/recordings/theirs.hqrec")"
check "run refuses a path that climbs out of the company" 'j["error"]=="package-outside-company"' \
  "$(run run describe "$hq/companies/acme/recordings/../../other/recordings/theirs.hqrec")"
check "run refuses a symlink to another company's recording" 'j["error"]=="package-outside-company"' \
  "$(run run describe "$hq/companies/acme/recordings/link.hqrec")"
check "run refuses a folder that is not a .hqrec package" 'j["error"]=="package-outside-company"' \
  "$(run run describe "$hq/companies/acme/recordings/notes")"
check "run refuses a nested path inside a package" 'j["error"]=="package-outside-company"' \
  "$(run run describe "$pkg/exports")"
check "run refuses a missing package" 'j["error"]=="no-package"' "$(run run describe "$hq/companies/acme/recordings/gone.hqrec")"
session "other"
check "run refuses the bound company's neighbor" 'j["error"]=="package-outside-company"' "$(run run describe "$pkg")"
session ""
check "run refuses with no bound company" 'j["error"]=="no-company"' "$(run run describe "$pkg")"
session "acme"

# run: passes the mode, the resolved package and the arguments to the app, and its exit code back.
real_pkg="$(python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$pkg")"
out="$(run run describe "$pkg" --json)"
check "run describe calls the app headless" "j[\"argv\"]==[\"--describe\", \"$real_pkg\", \"--json\"]" "$out"
out="$(cd "$hq/companies/acme/recordings" && bash "$R" run --edit demo.hqrec --in 1.5 --camera 0.8,0.8,0.18 --json)"
check "run accepts a relative package and a -- mode" \
  "j[\"argv\"]==[\"--edit\", \"$real_pkg\", \"--in\", \"1.5\", \"--camera\", \"0.8,0.8,0.18\", \"--json\"]" "$out"
out="$(run run sync-package "$pkg")"
check "run sync-package passes the HQ root" 'j["argv"][0]=="--sync-package" and j["argv"][-2]=="--hq-root" and j["argv"][-1].endswith("/hq")' "$out"
expect "run passes a refusal exit code through" "$(STUB_EXIT=1 code run export-sop "$pkg")" "1"
expect "run passes a cancel exit code through" "$(STUB_EXIT=130 code run export-video "$pkg")" "130"
expect "run exits 0 when the app succeeds" "$(code run frame "$pkg" --at 1 --out /tmp/x.png)" "0"

# run frame: --out may not land in another company's folder.
check "run frame refuses --out in another company" 'j["error"]=="out-outside-company"' \
  "$(run run frame "$pkg" --at 1 --out "$hq/companies/other/x.png")"
expect "run frame --out refusals exit 3" "$(code run frame "$pkg" --at 1 --out "$hq/companies/other/x.png")" "3"
check "run frame refuses --out= in another company" 'j["error"]=="out-outside-company"' \
  "$(run run frame "$pkg" --at 1 --out="$hq/companies/other/x.png")"
check "run frame refuses --out that climbs into another company" 'j["error"]=="out-outside-company"' \
  "$(run run frame "$pkg" --at 1 --out "$hq/companies/acme/../other/x.png")"
check "run frame refuses --out loose in companies/" 'j["error"]=="out-outside-company"' \
  "$(run run frame "$pkg" --at 1 --out "$hq/companies/x.png")"
check "run frame refuses a relative --out into another company" 'j["error"]=="out-outside-company"' \
  "$(cd "$hq/companies/acme" && bash "$R" run frame "$pkg" --at 1 --out ../other/x.png 2>/dev/null || true)"
out="$(run run frame "$pkg" --at 1 --out "$hq/companies/acme/recordings/still.png")"
check "run frame allows --out in the bound company" 'j["argv"][0]=="--frame" and j["argv"][-1].endswith("/companies/acme/recordings/still.png")' "$out"
out="$(run run frame "$pkg" --at 1 --out "${TMPDIR:-/tmp}/still.png")"
check "run frame allows --out in TMPDIR" 'j["argv"][0]=="--frame"' "$out"
out="$(run run frame "$pkg" --at 1 --out /tmp/still.png)"
check "run frame allows --out in /tmp" 'j["argv"][-1]=="/tmp/still.png"' "$out"
out="$(run run edit "$pkg" --out 4.5 --json)"
check "run edit's --out seconds are not treated as a path" 'j["argv"][0]=="--edit"' "$out"
# A company folder that is a symlink to somewhere outside companies/ is still that company's.
mkdir -p "$tmp/elsewhere/linked" "$tmp/elsewhere/loose"
printf '  linked:\n    name: Linked\n' >>"$hq/companies/manifest.yaml"
ln -s "$tmp/elsewhere/linked" "$hq/companies/linked"
check "run frame refuses --out through another company's symlinked folder" 'j["error"]=="out-outside-company"' \
  "$(run run frame "$pkg" --at 1 --out "$hq/companies/linked/x.png")"
check "run frame refuses --out at the real folder behind another company's symlink" 'j["error"]=="out-outside-company"' \
  "$(run run frame "$pkg" --at 1 --out "$tmp/elsewhere/linked/sub/x.png")"
ln -s "$tmp/elsewhere/linked" "$hq/companies/acme/recordings/sneaky"
check "run frame refuses a new --out under a bound-company symlink to another company" 'j["error"]=="out-outside-company"' \
  "$(run run frame "$pkg" --at 1 --out "$hq/companies/acme/recordings/sneaky/new/x.png")"
out="$(run run frame "$pkg" --at 1 --out "$tmp/elsewhere/loose/x.png")"
check "run frame still allows --out in a folder no company points at" 'j["argv"][0]=="--frame"' "$out"
rm "$hq/companies/acme/recordings/sneaky"

# run: the guide review, approval and frame list modes pass through like the others.
out="$(run run review-sop "$pkg" --move 3 1 --reword 2 "Click Save" --drop 4 --json)"
check "run review-sop passes every change to the app" \
  "j[\"argv\"]==[\"--review-sop\", \"$real_pkg\", \"--move\", \"3\", \"1\", \"--reword\", \"2\", \"Click Save\", \"--drop\", \"4\", \"--json\"]" "$out"
out="$(run run --approve-sop "$pkg" --reviewer "Pat Lee" --revision drafts/draft-003.json --json)"
check "run approve-sop passes the reviewer and the shown revision" \
  "j[\"argv\"]==[\"--approve-sop\", \"$real_pkg\", \"--reviewer\", \"Pat Lee\", \"--revision\", \"drafts/draft-003.json\", \"--json\"]" "$out"
# Approval binds to the revision the user was shown, so approve-sop must name it.
check "run approve-sop refuses without --revision" 'j["error"]=="bad-argument" and "--revision" in j["message"]' \
  "$(run run approve-sop "$pkg" --reviewer "Pat Lee" --json)"
expect "run approve-sop without --revision exits 3" "$(code run approve-sop "$pkg" --reviewer "Pat Lee")" "3"
check "run approve-sop refuses an empty --revision" 'j["error"]=="bad-argument"' \
  "$(run run approve-sop "$pkg" --reviewer "Pat Lee" --revision "")"
check "run approve-sop refuses --revision with no value" 'j["error"]=="bad-argument"' \
  "$(run run approve-sop "$pkg" --reviewer "Pat Lee" --revision)"
skill="$here/../skills/record-process/SKILL.md"
expect "every approve-sop in the skill passes --revision" \
  "$(grep -E 'run approve-sop' "$skill" | grep -vc -- '--revision' || true)" "0"
expect "the skill shows at least one approve-sop call" "$(grep -cE 'run approve-sop' "$skill")" "1"
out="$(run run list-frames "$pkg" --step 2 --json)"
check "run list-frames passes the step" "j[\"argv\"]==[\"--list-frames\", \"$real_pkg\", \"--step\", \"2\", \"--json\"]" "$out"
out="$(run run edit "$pkg" --cut 3.2-4.1 --cut 9-9.6 --json)"
check "run edit passes repeated cuts" \
  "j[\"argv\"]==[\"--edit\", \"$real_pkg\", \"--cut\", \"3.2-4.1\", \"--cut\", \"9-9.6\", \"--json\"]" "$out"
check "run review-sop refuses another company's recording" 'j["error"]=="package-outside-company"' \
  "$(run run review-sop "$hq/companies/other/recordings/theirs.hqrec" --drop 1)"
check "run approve-sop refuses a symlink to another company's recording" 'j["error"]=="package-outside-company"' \
  "$(run run approve-sop "$hq/companies/acme/recordings/link.hqrec" --reviewer Pat --revision drafts/draft-001.json)"
check "run list-frames refuses a company override" 'j["error"]=="bad-argument"' "$(run run list-frames "$pkg" --company other)"
check "run review-sop refuses a destination override" 'j["error"]=="bad-argument"' "$(run run review-sop "$pkg" --destination /tmp)"
check "run rejects approve-sop given as a second mode" 'j["error"]=="bad-argument"' "$(run run review-sop "$pkg" --approve-sop)"
check "run rejects list-frames given as a second mode" 'j["error"]=="bad-argument"' "$(run run describe "$pkg" --list-frames)"
session "other"
check "run review-sop refuses in a session bound to another company" 'j["error"]=="package-outside-company"' "$(run run review-sop "$pkg" --drop 1)"
session "acme"

# resume: parses the app's prompt and checks it against the bound company.
out="$(run resume "$prompt")"
check "resume accepts the app's prompt" "j[\"ok\"] and j[\"company\"]==\"acme\" and j[\"package\"]==\"$real_pkg\"" "$out"
wrapped="$(python3 -I -c 'import sys; p=sys.argv[1]; i=p.index(": show"); print(p[:i].replace(" recording for ", " recording\n  for ") + ":\n" + p[i+2:])' "$prompt")"
check "resume accepts the prompt with line breaks" "j[\"ok\"] and j[\"package\"]==\"$real_pkg\"" "$(run resume "$wrapped")"
check "resume accepts the prompt among other words" "j[\"ok\"]" "$(run resume "please: $prompt thanks")"
check "resume rejects text that is not the prompt" 'j["error"]=="not-a-resume-prompt"' "$(run resume "trim my last video")"
check "resume rejects an empty prompt" 'j["error"]=="bad-argument"' "$(run resume)"
other_prompt="Continue my HQ Capture recording for other at $hq/companies/other/recordings/theirs.hqrec: show me what was recorded, then trim, place the camera, export the video and draft the step-by-step guide."
check "resume refuses another company's prompt" 'j["error"]=="company-mismatch"' "$(run resume "$other_prompt")"
sneaky="Continue my HQ Capture recording for acme at $hq/companies/other/recordings/theirs.hqrec: show me what was recorded."
check "resume refuses a path outside the company's recordings" 'j["error"]=="package-outside-company"' "$(run resume "$sneaky")"
expect "resume refusals exit 3" "$(code resume "$sneaky")" "3"
session "other"
check "resume refuses in a session bound to another company" 'j["error"]=="company-mismatch"' "$(run resume "$prompt")"
session "acme"

# Lost app.
check "start opens again" 'j["state"]=="awaiting-start"' "$(run start)"
kill -9 "$(cat "$tmp/apps/stub.pid")"; sleep 0.2
check "a vanished app is reported as lost" 'j["state"]=="lost"' "$(run status)"
check "wait returns on a lost app" 'j["state"]=="lost"' "$(last "$(run wait --timeout 2)")"
check "start is allowed after a lost app" 'j["state"]=="awaiting-start"' "$(run start)"
check "stop closes" 'j["state"]=="closed"' "$(run stop)"

# An app that does not answer a stop request is not reported as stopped.
touch "$tmp/ignore.stop"
check "start opens for the stop-timeout checks" 'j["state"]=="awaiting-start"' "$(run start)"
out="$(HQ_RECORDER_STOP_WAIT=1 run stop)"
check "stop times out on an app that ignores it before recording" \
  'j["ok"] is False and j["error"]=="stop-timeout" and "may still be recording" in j["message"] and "awaiting-start" in j["message"]' "$out"
touch "$tmp/go.record"; sleep 0.5
expect "a stop timeout exits 1" "$(HQ_RECORDER_STOP_WAIT=1 code stop)" "1"
out="$(HQ_RECORDER_STOP_WAIT=1 run stop)"
check "stop times out on a recording that ignores it" \
  'j["error"]=="stop-timeout" and "(status: recording)" in j["message"]' "$out"
check "the recording is still running after a stop timeout" 'j["state"]=="recording"' "$(run status)"
touch "$tmp/finalize.stop"; rm -f "$tmp/ignore.stop"
out="$(HQ_RECORDER_STOP_WAIT=1 run stop)"
check "stop succeeds when the app is finalizing" 'j["ok"] and j["state"]=="finalizing"' "$out"
expect "stop while finalizing exits 0" "$(HQ_RECORDER_STOP_WAIT=1 code stop)" "0"
kill "$(cat "$tmp/apps/stub.pid")"; sleep 0.2
rm -f "$tmp/go.record" "$tmp/finalize.stop" "$HQ_RECORDER_HOME"/*/stop.request 2>/dev/null || true

# Two starts at once open one app. The second reports already-open once the first app is open,
# or busy if the first is still opening it.
before="$(launches)"
bash "$R" start >"$tmp/start1.out" 2>/dev/null & s1=$!
bash "$R" start >"$tmp/start2.out" 2>/dev/null & s2=$!
wait "$s1" || true; wait "$s2" || true
expect "two starts at once launch exactly one app" "$(( $(launches) - before ))" "1"
both="$(cat "$tmp/start1.out" "$tmp/start2.out")"
expect "one of two starts at once opens the app" "$(grep -c '"state": "awaiting-start"' <<<"$both")" "1"
expect "the other start reports already-open or busy" "$(grep -cE '"error": "(already-open|busy)"' <<<"$both")" "1"
[ ! -e "$HQ_RECORDER_HOME/.start.lock" ] && pass=$((pass + 1)) \
  || { echo "FAIL: start should release its lock" >&2; exit 1; }
check "stop closes the one app" 'j["state"]=="closed"' "$(run stop)"
mkdir -p "$HQ_RECORDER_HOME/.start.lock"
sleep 60 & holder=$!
echo "$holder" >"$HQ_RECORDER_HOME/.start.lock/pid"
before="$(launches)"
check "start reports busy while another start holds the lock" 'j["ok"] is False and j["error"]=="busy"' "$(HQ_RECORDER_START_WAIT=1 run start)"
expect "a busy start exits 1" "$(HQ_RECORDER_START_WAIT=1 code start)" "1"
expect "a busy start launches nothing" "$(launches)" "$before"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
check "start clears a start lock left by a process that exited" 'j["state"]=="awaiting-start"' "$(HQ_RECORDER_START_WAIT=1 run start)"
check "stop closes it" 'j["state"]=="closed"' "$(run stop)"

# fake_status <company> <state> <pid>: a status.json as the app writes it, with a saved
# recording and resume prompt.
fake_status() {
  python3 -I -c '
import json, os, sys
path, company, state, pid, dest = sys.argv[1:]
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"schema": 1, "state": state, "company": company, "destination": dest, "pid": int(pid),
           "recording": "companies/%s/recordings/theirs.hqrec" % company,
           "resumePrompt": "Continue my HQ Capture recording for %s at %s/theirs.hqrec: show me." % (company, dest),
           "updatedAt": "2026-01-01T00:00:00Z"}, open(path, "w"))' \
    "$HQ_RECORDER_HOME/active/status.json" "$1" "$2" "$3" "$hq/companies/$1/recordings"
}
# A pid that has exited. It is taken from a child that python3 started and reaped, not from
# `sleep & kill`: a background child killed before it execs still carries this script's EXIT
# trap, and would run cleanup and delete $tmp in the middle of the test.
gone="$(python3 -I -c 'import subprocess; p = subprocess.Popen(["true"]); p.wait(); print(p.pid)')"

# A status whose pid is now a different program (here this test's shell) is not HQ Capture.
fake_status acme recording $$
check "a status naming a live pid that is not HQ Capture is lost" 'j["state"]=="lost"' "$(run status)"
check "start proceeds over a status naming another program's pid" 'j["state"]=="awaiting-start"' "$(run start)"
check "stop closes it" 'j["state"]=="closed"' "$(run stop)"
fake_status acme saved $$
check "stop on a saved status naming another program's pid is a no-op" 'j["state"]=="saved"' "$(run stop)"
check "start proceeds over a saved status naming another program's pid" 'j["state"]=="awaiting-start"' "$(run start)"
check "stop closes it" 'j["state"]=="closed"' "$(run stop)"

# Another company's finished recording, whose app has exited, does not block this company and
# none of it is shown here.
for st in saved failed closed; do
  fake_status other "$st" "$gone"
  check "status is none over another company's exited $st app" 'j=={"ok": True, "state": "none"}' "$(run status)"
  check "stop is a no-op over another company's exited $st app" 'j=={"ok": True, "state": "none"}' "$(run stop)"
  expect "stop over another company's exited $st app exits 0" "$(code stop)" "0"
  check "wait over another company's exited $st app is not-open" 'j["error"]=="not-open" and "other" not in j["message"]' "$(run wait --timeout 1)"
done
fake_status other saved "$gone"
out="$(run start)"
check "start proceeds over another company's exited app" 'j["state"]=="awaiting-start" and j["company"]=="acme"' "$out"
check "start replaced the other company's status" 'j["company"]=="acme" and "resumePrompt" not in j' "$(run status)"
check "stop closes it" 'j["state"]=="closed"' "$(run stop)"
# While the other company's saved app is still running, it stays redacted and blocks this company.
python3 -I -c 'import time; time.sleep(60)' & live=$!
sleep 0.3
fake_status other saved "$live"
check "status is redacted while another company's saved app is running" 'j=={"ok": True, "state": "busy-other-company"}' "$(run status)"
check "stop is refused while another company's saved app is running" 'j["error"]=="other-company"' "$(run stop)"
check "start is refused while another company's saved app is running" 'j["error"]=="already-open"' "$(run start)"
kill "$live" 2>/dev/null || true; wait "$live" 2>/dev/null || true
check "status is none once that app has exited" 'j=={"ok": True, "state": "none"}' "$(run status)"
rm -rf "$HQ_RECORDER_HOME/active"

# Permission relaunch: the app quit for macOS Quit & Reopen and reported relaunching.
fake_status acme relaunching "$gone"
check "a fresh relaunching status is reported as relaunching" 'j["state"]=="relaunching"' "$(run status)"
check "start is refused while macOS reopens the app" 'j["error"]=="already-open"' "$(run start)"
expect "wait keeps waiting through relaunching" "$(set +e; bash "$R" wait --timeout 1 >/dev/null 2>&1; echo $?)" "3"
# The reopened app reports awaiting-start under its own pid; wait follows it instead of returning.
python3 -I -c 'import time; time.sleep(60)' & reopened=$!
( python3 -I -c 'import time; time.sleep(1.2)'
  fake_status acme awaiting-start "$reopened" ) &
out="$(set +e; bash "$R" wait --timeout 4 2>/dev/null; echo "exit=$?")"
check "wait prints relaunching first" 'j["state"]=="relaunching"' "$(head -n 1 <<<"$out")"
check "wait then follows the reopened app" 'j["event"]=="state" and j["state"]=="awaiting-start"' "$(sed -n 2p <<<"$out")"
expect "wait is still open at its timeout" "$(last "$out")" "exit=3"
kill "$reopened" 2>/dev/null || true; wait "$reopened" 2>/dev/null || true
# If no reopened app reports within the relaunch wait, it was a plain quit.
fake_status acme relaunching "$gone"
check "a relaunching status with no reopened app becomes closed" 'j["state"]=="closed"' \
  "$(HQ_RECORDER_RELAUNCH_WAIT=0 run status)"
check "wait returns closed once the relaunch wait has passed" 'j["state"]=="closed"' \
  "$(last "$(HQ_RECORDER_RELAUNCH_WAIT=0 run wait --timeout 2)")"
check "start proceeds once the relaunch wait has passed" 'j["state"]=="awaiting-start"' "$(HQ_RECORDER_RELAUNCH_WAIT=0 run start)"
check "stop closes it" 'j["state"]=="closed"' "$(run stop)"
rm -rf "$HQ_RECORDER_HOME/active"

# Build lock: a build waits for a live lock holder and clears a lock left by a dead one.
mkdir -p "$HQ_RECORDER_HOME/.build.lock"
sleep 60 & holder=$!
echo "$holder" >"$HQ_RECORDER_HOME/.build.lock/pid"
check "build refuses while another build holds the lock" 'j["ok"] is False and j["error"]=="build-busy"' \
  "$(HQ_RECORDER_LOCK_WAIT=1 run build --force)"
expect "nothing was built while the lock was held" "$(builds)" "3"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
check "build clears a lock left by a process that exited" 'j["ok"] and j["built"] is True' "$(HQ_RECORDER_LOCK_WAIT=1 run build --force)"
[ ! -e "$HQ_RECORDER_HOME/.build.lock" ] && pass=$((pass + 1)) \
  || { echo "FAIL: build should release its lock" >&2; exit 1; }
# A lock with no pid is waited on while it is new, and cleared once it is older than 30 seconds.
mkdir -p "$HQ_RECORDER_HOME/.build.lock"
check "build waits on a new lock with no pid" 'j["error"]=="build-busy"' "$(HQ_RECORDER_LOCK_WAIT=1 run build --force)"
python3 -I -c 'import os,sys,time; t=time.time()-60; os.utime(sys.argv[1], (t, t))' "$HQ_RECORDER_HOME/.build.lock"
check "build clears a lock with no pid older than 30 seconds" 'j["ok"] and j["built"] is True' "$(HQ_RECORDER_LOCK_WAIT=1 run build --force)"
[ ! -e "$HQ_RECORDER_HOME/.build.lock" ] && pass=$((pass + 1)) \
  || { echo "FAIL: build should release the lock it took over" >&2; exit 1; }

# Several builds that all find the same stale lock: only one takes it over at a time. The race
# compiler marks itself inside with mkdir, so a second build inside at once is recorded.
cat >"$tmp/race-compile.sh" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
mkdir "$d/race.inside" 2>/dev/null || echo overlap >>"$d/race.log"
sleep 0.4
rmdir "$d/race.inside" 2>/dev/null || true
exec "$d/stub-compile.sh" "$@"
EOF
chmod +x "$tmp/race-compile.sh"
rm -f "$tmp/race.log"
for round in 1 2 3; do
  rm -rf "$HQ_RECORDER_HOME/.build.lock"; mkdir -p "$HQ_RECORDER_HOME/.build.lock"
  echo "$gone" >"$HQ_RECORDER_HOME/.build.lock/pid"
  pids=()
  for i in 1 2 3 4 5 6; do
    HQ_RECORDER_COMPILE="$tmp/race-compile.sh" HQ_RECORDER_LOCK_WAIT=30 HQ_RECORDER_TAKEOVER_PAUSE=0.3 \
      bash "$R" build --force >/dev/null 2>&1 & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
done
expect "builds racing for a stale lock never build at the same time" "$( [ -f "$tmp/race.log" ] && wc -l <"$tmp/race.log" | tr -d ' ' || echo 0)" "0"
nested="$(find "$HQ_RECORDER_HOME" -path '*HQ Capture.app/*HQ Capture.app' -print -quit)"
expect "racing builds never nest one app inside another" "$nested" ""

# A lock naming a live pid whose start time differs (the pid was reused by another program) is stale.
mkdir -p "$HQ_RECORDER_HOME/.build.lock"
printf '%s\n%s\n' "$$" "Thu Jan  1 00:00:00 1970" >"$HQ_RECORDER_HOME/.build.lock/pid"
check "build clears a lock whose pid now belongs to a later process" 'j["ok"] and j["built"] is True' \
  "$(HQ_RECORDER_LOCK_WAIT=1 run build --force)"
# A lock naming a live pid with its real start time is held.
mkdir -p "$HQ_RECORDER_HOME/.build.lock"
sleep 60 & holder=$!
printf '%s\n%s\n' "$holder" "$(ps -p "$holder" -o lstart=)" >"$HQ_RECORDER_HOME/.build.lock/pid"
check "build waits on a lock whose pid and start time match a live process" 'j["error"]=="build-busy"' \
  "$(HQ_RECORDER_LOCK_WAIT=1 run build --force)"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
rm -rf "$HQ_RECORDER_HOME/.build.lock"

# Installing the new app never moves it inside an app that appeared at the same path.
cat >"$tmp/install-hook.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$1/Contents/MacOS" && echo intruder >"$1/Contents/MacOS/intruder"
EOF
chmod +x "$tmp/install-hook.sh"
out="$(HQ_RECORDER_INSTALL_HOOK="$tmp/install-hook.sh" run build --force)"
check "build refuses to install over an app that appeared during the install" 'j["ok"] is False and j["error"]=="install-conflict"' "$out"
expect "the refused install nested nothing" "$(find "$HQ_RECORDER_HOME" -path '*HQ Capture.app/*HQ Capture.app' -print -quit)" ""
check "the next build installs normally" 'j["ok"] and j["built"] is True' "$(run build --force)"
[ ! -e "$HQ_RECORDER_HOME/HQ Capture.app/Contents/MacOS/intruder" ] && pass=$((pass + 1)) \
  || { echo "FAIL: the next build should replace the intruding app" >&2; exit 1; }
# A build whose lock was taken over while it compiled does not install.
cat >"$tmp/steal-compile.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 1 >"$HQ_RECORDER_HOME/.build.lock/pid"
exec "$(dirname "$0")/stub-compile.sh" "$@"
EOF
chmod +x "$tmp/steal-compile.sh"
check "a build that lost its lock does not install" 'j["ok"] is False and j["error"]=="build-busy"' \
  "$(HQ_RECORDER_COMPILE="$tmp/steal-compile.sh" run build --force)"
rm -rf "$HQ_RECORDER_HOME/.build.lock"

# The build recipe is part of the rebuild hash.
sed -i.bak 's/-swift-version 6 -O/-swift-version 6 -Osize/' "$R" && rm -f "$R.bak"
check "a build recipe change makes build rebuild" 'j["ok"] and j["built"] is True' "$(run build)"
check "an unchanged recipe does not rebuild" 'j["ok"] and j["built"] is False' "$(run build)"

doc="$(bash "$R" doctor 2>/dev/null || true)"
if [ "$(uname -s)" = Darwin ]; then
  check "doctor reports each check on macOS" '"command_line_tools" in j and "macos_26_or_later" in j' "$doc"
else
  check "doctor fails off macOS with a fix" 'j["ok"] is False and j["macos"] is False and "fix" in j' "$doc"
fi

# doctor prints its JSON, including the fix line, on a machine without python3.
nopy="$tmp/nopy-bin"
mkdir -p "$nopy"
for d in /usr/bin /bin /usr/sbin /sbin; do
  for f in "$d"/*; do
    n="$(basename "$f")"
    case "$n" in python*) continue ;; esac
    [ -x "$f" ] && [ ! -e "$nopy/$n" ] && ln -s "$f" "$nopy/$n"
  done
done
expect "the no-python3 PATH has no python3" "$(PATH="$nopy" command -v python3 || echo none)" "none"
doc="$(PATH="$nopy" bash "$R" doctor 2>/dev/null || true)"
check "doctor prints valid JSON without python3" '"ok" in j and "macos" in j and "apple_silicon" in j' "$doc"
# Force a failing check (an Intel uname) to see the fix line without python3.
rm -f "$nopy/uname"
printf '#!/bin/sh\n[ "$1" = -m ] && echo x86_64 || /usr/bin/uname "$@"\n' >"$nopy/uname"
chmod +x "$nopy/uname"
doc="$(PATH="$nopy" bash "$R" doctor 2>/dev/null || true)"
expect "doctor exits 1 when a check fails" "$(set +e; PATH="$nopy" bash "$R" doctor >/dev/null 2>&1; echo $?)" "1"
check "doctor prints the fix line without python3" \
  'j["ok"] is False and j["apple_silicon"] is False and j["apple_silicon_detail"]=="x86_64" and j["fix"].startswith("Run: xcode-select --install")' "$doc"

echo "record-process launcher: $pass checks passed"
