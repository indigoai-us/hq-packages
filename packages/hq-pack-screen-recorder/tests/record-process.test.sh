#!/usr/bin/env bash
# Launcher tests for hq-record-process.sh. Safe on any OS: the real app is
# replaced by a stub that speaks the same file control channel
# (status.json + stop.request). The macOS build-and-launch path is covered by
# tests/e2e-macos.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$here/../scripts/hq-record-process.sh"

tmp="$(mktemp -d)"
cleanup() {
  [ -f "$tmp/stub.pid" ] && kill "$(cat "$tmp/stub.pid")" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# Fake HQ root with two companies and a session helper.
hq="$tmp/hq"
mkdir -p "$hq/companies/acme" "$hq/companies/other" "$hq/core/scripts"
printf 'companies:\n  acme:\n    name: Acme\n  other:\n    name: Other\n' >"$hq/companies/manifest.yaml"
cat >"$hq/core/scripts/hq-session.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "get company_slug" ] && cat "$(dirname "$0")/session-company"
EOF
session() { printf '%s' "$1" >"$hq/core/scripts/session-company"; }

# Stub app: records its argv, writes awaiting-start, closes on stop.request.
cat >"$tmp/stub-open.sh" <<'EOF'
#!/usr/bin/env bash
app="$1"; shift; [ "$1" = --args ] && shift
printf '%s\n' "$@" >"$app.argv"
python3 -I - "$@" <<'PY' >/dev/null 2>&1 &
import json, os, sys, time
args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
ctl = args["--hq-control"]
def write(state):
    s = {"schema": 1, "state": state, "company": args["--company"],
         "destination": args["--destination"], "pid": os.getpid(),
         "updatedAt": "2026-01-01T00:00:00Z"}
    tmp = os.path.join(ctl, ".status.tmp")
    with open(tmp, "w") as f: json.dump(s, f)
    os.replace(tmp, os.path.join(ctl, "status.json"))
write("awaiting-start")
while not os.path.exists(os.path.join(ctl, "stop.request")):
    time.sleep(0.05)
os.remove(os.path.join(ctl, "stop.request"))
write("closed")
PY
echo $! >"$(dirname "$app")/stub.pid"
EOF
chmod +x "$tmp/stub-open.sh"
touch "$tmp/stub.app"

export HQ_ROOT="$hq"
export HQ_RECORDER_HOME="$tmp/state"
export HQ_RECORDER_APP="$tmp/stub.app"
export HQ_RECORDER_OPEN="$tmp/stub-open.sh"

pass=0
check() { # check <description> <python expression over j> <json>
  if python3 -I -c 'import json,sys; j=json.loads(sys.argv[2]); sys.exit(0 if eval(sys.argv[1]) else 1)' "$2" "$3"; then
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n  got: %s\n' "$1" "$3" >&2; exit 1
  fi
}
run() { bash "$R" "$@" 2>/dev/null || true; }

session ""
check "no company in session is refused" 'j["ok"] is False and j["error"]=="no-company"' "$(run start)"
session "personal"
check "personal session is refused" 'j["error"]=="no-company"' "$(run start)"
check "unknown company is refused" 'j["error"]=="unknown-company"' "$(run start --company ghost)"
check "invalid company name is refused" 'j["error"]=="bad-company"' "$(run start --company ../acme)"
[ ! -e "$HQ_RECORDER_HOME/active/status.json" ] && pass=$((pass + 1))
check "status before any start is none" 'j["state"]=="none"' "$(run status)"

session "acme"
out="$(run start)"
check "start opens the recorder awaiting user start" \
  'j["ok"] and j["state"]=="awaiting-start" and j["company"]=="acme" and j["destination"].endswith("/companies/acme/recordings")' "$out"
[ -d "$hq/companies/acme/recordings" ] && [ -z "$(ls -A "$hq/companies/acme/recordings")" ] && pass=$((pass + 1)) \
  || { echo "FAIL: destination should exist and be empty" >&2; exit 1; }
grep -qx -- "--company" "$tmp/stub.app.argv" && grep -qx "acme" "$tmp/stub.app.argv" && pass=$((pass + 1)) \
  || { echo "FAIL: app did not receive the company" >&2; exit 1; }

check "a second start is refused while open" 'j["error"]=="already-open"' "$(run start --company other)"
check "status reports the open recorder" 'j["state"]=="awaiting-start" and j["company"]=="acme"' "$(run status)"
check "stop closes the recorder" 'j["state"]=="closed"' "$(run stop)"
check "stop when closed is a no-op" 'j["state"]=="closed"' "$(run stop)"

session "other"
check "start works again after stop, for the new company" 'j["state"]=="awaiting-start" and j["company"]=="other"' "$(run start)"
kill -9 "$(cat "$tmp/stub.pid")"; sleep 0.2
check "a vanished app is reported as lost" 'j["state"]=="lost"' "$(run status)"
check "start is allowed after a lost app" 'j["state"]=="awaiting-start"' "$(run start)"
check "stop closes it" 'j["state"]=="closed"' "$(run stop)"

doc="$(bash "$R" doctor 2>/dev/null || true)"
if [ "$(uname -s)" = Darwin ]; then
  check "doctor reports each check on macOS" '"command_line_tools" in j and "macos_26_or_later" in j' "$doc"
else
  check "doctor fails off macOS with a fix" 'j["ok"] is False and j["macos"] is False and "fix" in j' "$doc"
fi

echo "record-process launcher: $pass checks passed"
