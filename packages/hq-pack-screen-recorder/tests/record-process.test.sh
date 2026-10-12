#!/usr/bin/env bash
# Launcher tests for hq-record-process.sh. Safe on any OS: the compiler is replaced by a
# stub that writes a fake HQ Capture.app whose executable echoes its arguments, and the
# opener is replaced by a stub that speaks the same file control channel as the real app
# (status.json + stop.request). The real macOS build and launch are covered by
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

# Fake HQ root with two companies and a session helper.
hq="$tmp/hq"
mkdir -p "$hq/companies/acme" "$hq/companies/other" "$hq/core/scripts"
printf 'companies:\n  acme:\n    name: Acme\n  other:\n    name: Other\n' >"$hq/companies/manifest.yaml"
cat >"$hq/core/scripts/hq-session.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "get company_slug" ] && cat "$(dirname "$0")/session-company"
EOF
session() { printf '%s' "$1" >"$hq/core/scripts/session-company"; }

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
while not os.path.exists(os.path.join(ctl, "stop.request")):
    if not recording and os.path.exists(go):
        recording = True
        write("recording", paused=False, durationSeconds=1.5)
    time.sleep(0.05)
os.remove(os.path.join(ctl, "stop.request"))
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
    write("saved", recording=rel, durationSeconds=2.0, resumePrompt=prompt, reason="stop-requested", **extra)
else:
    write("closed")
PY
echo $! >"$(dirname "$app")/stub.pid"
EOF
chmod +x "$tmp/stub-open.sh"

mkdir -p "$tmp/apps" "$tmp/legacy/HQ Recorder.app/Contents" "$tmp/state/LocalScreenRecorder.app/Contents"
touch "$tmp/legacy/build.stamp" "$tmp/legacy/keep.txt"
export HQ_ROOT="$hq"
export HQ_RECORDER_HOME="$tmp/state"
export HQ_RECORDER_APP="$tmp/apps/HQ Capture.app"
export HQ_RECORDER_OPEN="$tmp/stub-open.sh"
export HQ_RECORDER_COMPILE="$tmp/stub-compile.sh"
export HQ_RECORDER_LEGACY_HOME="$tmp/legacy"
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
check "unknown company is refused" 'j["error"]=="unknown-company"' "$(run start --company ghost)"
check "invalid company name is refused" 'j["error"]=="bad-company"' "$(run start --company ../acme)"
check "--company without a value is refused" 'j["error"]=="bad-argument"' "$(run start --company)"
[ ! -e "$HQ_RECORDER_HOME/active/status.json" ] && pass=$((pass + 1))
check "status before any start is none" 'j["state"]=="none"' "$(run status)"
check "wait before any start is refused" 'j["error"]=="not-open"' "$(run wait --timeout 1)"
session "acme"
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

# run: the guide review, approval and frame list modes pass through like the others.
out="$(run run review-sop "$pkg" --move 3 1 --reword 2 "Click Save" --drop 4 --json)"
check "run review-sop passes every change to the app" \
  "j[\"argv\"]==[\"--review-sop\", \"$real_pkg\", \"--move\", \"3\", \"1\", \"--reword\", \"2\", \"Click Save\", \"--drop\", \"4\", \"--json\"]" "$out"
out="$(run run --approve-sop "$pkg" --reviewer "Pat Lee" --json)"
check "run approve-sop passes the reviewer" \
  "j[\"argv\"]==[\"--approve-sop\", \"$real_pkg\", \"--reviewer\", \"Pat Lee\", \"--json\"]" "$out"
out="$(run run list-frames "$pkg" --step 2 --json)"
check "run list-frames passes the step" "j[\"argv\"]==[\"--list-frames\", \"$real_pkg\", \"--step\", \"2\", \"--json\"]" "$out"
out="$(run run edit "$pkg" --cut 3.2-4.1 --cut 9-9.6 --json)"
check "run edit passes repeated cuts" \
  "j[\"argv\"]==[\"--edit\", \"$real_pkg\", \"--cut\", \"3.2-4.1\", \"--cut\", \"9-9.6\", \"--json\"]" "$out"
check "run review-sop refuses another company's recording" 'j["error"]=="package-outside-company"' \
  "$(run run review-sop "$hq/companies/other/recordings/theirs.hqrec" --drop 1)"
check "run approve-sop refuses a symlink to another company's recording" 'j["error"]=="package-outside-company"' \
  "$(run run approve-sop "$hq/companies/acme/recordings/link.hqrec" --reviewer Pat)"
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

doc="$(bash "$R" doctor 2>/dev/null || true)"
if [ "$(uname -s)" = Darwin ]; then
  check "doctor reports each check on macOS" '"command_line_tools" in j and "macos_26_or_later" in j' "$doc"
else
  check "doctor fails off macOS with a fix" 'j["ok"] is False and j["macos"] is False and "fix" in j' "$doc"
fi

echo "record-process launcher: $pass checks passed"
