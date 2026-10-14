#!/usr/bin/env bash
# Port of hq-core-staging's hqd-hook-shim.test.sh, run against both packaged
# shim copies. It uses a temporary HOME and never touches the real ~/.hq.

HERE=$(cd "$(dirname "$0")" && pwd)
UNREACHABLE='HQ daemon unreachable: run hq daemon status'

SHIMS=(
  "$HERE/../plugins/hq-anywhere/scripts/hq/hqd-hook-shim.sh"
  "$HERE/../packages/hq-pack-hq-anywhere/hooks/codex-hook-shim.sh"
)
if [ -n "${HQD_TEST_SHIM:-}" ]; then SHIMS=("$HQD_TEST_SHIM"); fi
if [ -z "${HQD_TEST_SHIM:-}" ]; then
  for shim in "${SHIMS[@]}"; do HQD_TEST_SHIM="$shim" bash "$0" || exit $?; done
  exit 0
fi
SHIM=$HQD_TEST_SHIM
SHIM_DIR=$(cd "$(dirname "$SHIM")" && pwd)

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

TMP=$(mktemp -d /tmp/hqshim.XXXXXX)
STUB_PID=''
HQD_PID=''
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  [ -n "$HQD_PID" ] && kill "$HQD_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

export HOME="$TMP/home"
mkdir -p "$HOME/.hq"
HQ_COMPANY_UID=cmp_123456
export HQ_COMPANY_UID
flag_now=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || date +%s)
FLAG_CACHE="$HOME/.hq/hq-anywhere-runtime.flag.$HQ_COMPANY_UID"
printf 'false %s\n' "$flag_now" >"$FLAG_CACHE"
unset HQ_REGISTRY_DIR

# run_shim <socket> <payload> [args...] -> $RC, $OUT, $ERR
run_shim() {
  _sock="$1"; _payload="$2"; shift 2
  printf '%s' "$_payload" | HQ_HQD_SOCKET="$_sock" sh "$SHIM" "$@" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# Stub hqd: answers every request line with $2 (or never, when $2 is "hang").
start_stub() {
  _sock="$1"; _reply="$2"
  rm -f "$_sock" "$TMP/req"
  STUB_REPLY="$_reply" STUB_REQ="$TMP/req" perl -e '
use IO::Socket::UNIX;
my $srv = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 5) or die "listen: $!";
while (my $c = $srv->accept) {
  my $line = <$c>;
  open my $f, ">", $ENV{STUB_REQ}; print $f $line; close $f;
  if ($ENV{STUB_REPLY} eq "hang") { sleep 5; next; }
  print $c $ENV{STUB_REPLY}, "\n"; close $c;
}' "$_sock" &
  STUB_PID=$!
  _i=0
  while [ ! -S "$_sock" ] && [ $_i -lt 50 ]; do sleep 0.1; _i=$((_i + 1)); done
}
stop_stub() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=''; }

WRITE_OTHERCO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/foreign-repo","tool_name":"Write","tool_input":{"file_path":"companies/otherco/x.md","content":"hi"}}'
WRITE_ABS='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/foreign-repo","tool_name":"Edit","tool_input":{"file_path":"/opt/HQ/companies/indigo/a.md"}}'
BASH_OTHERCO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo hi > companies/otherco/x.md"}}'
EXEC_CMD_OTHERCO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"exec_command","tool_input":{"cmd":"printf x > companies/otherco/x.md"}}'
WRITE_OTHER='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/foreign-repo","tool_name":"Write","tool_input":{"file_path":"/tmp/foreign-repo/notes.md"}}'
READ_OTHERCO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Read","tool_input":{"file_path":"companies/otherco/x.md"}}'
START='{"session_id":"s1","hook_event_name":"SessionStart","cwd":"/tmp/foreign-repo","source":"startup"}'
PROMPT='{"session_id":"s1","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"hi"}'

# ---------------------------------------------------------------- part 1
NOSOCK="$TMP/absent.sock"
# hqd is expected on this machine (the daemon's enabled marker sits beside the
# socket path), so an absent socket below means "hqd unreachable".
: >"$TMP/hqd.enabled"

HQ_TEST_FLAG=false run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ]; then pass "flag off: shim is inert"
else fail "flag off: shim is inert" "rc=$RC out=$OUT err=$ERR"; fi

HQ_TEST_FLAG=true
export HQ_TEST_FLAG
printf 'true %s\n' "$(awk '{print int($1)}' /proc/uptime 2>/dev/null || date +%s)" >"$FLAG_CACHE"

# hqd not set up on this machine (HQ Anywhere off in settings): no socket and no
# enabled marker. The shim must not block work it has no daemon to route to.
mkdir -p "$TMP/hqd-off"
run_shim "$TMP/hqd-off/hqd.sock" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ]; then pass "hqd not set up (no socket, no marker): company write is not blocked"
else fail "hqd not set up (no socket, no marker): company write is not blocked" "rc=$RC out=$OUT err=$ERR"; fi
run_shim "$TMP/hqd-off/hqd.sock" "$READ_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ]; then pass "hqd not set up: company read is not blocked"
else fail "hqd not set up: company read is not blocked" "rc=$RC out=$OUT err=$ERR"; fi
# A stale socket file without the marker still means hqd was running: fail closed.
mkdir -p "$TMP/hqd-stale"
perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => IO::Socket::UNIX::SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die "listen: $!"' "$TMP/hqd-stale/hqd.sock"
run_shim "$TMP/hqd-stale/hqd.sock" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "stale hqd socket without marker: company write still fails closed"
else fail "stale hqd socket without marker: company write still fails closed" "rc=$RC err=$ERR"; fi
# The marker alone (daemon says hqd should run, socket gone): fail closed.
mkdir -p "$TMP/hqd-marker"
: >"$TMP/hqd-marker/hqd.enabled"
run_shim "$TMP/hqd-marker/hqd.sock" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "enabled marker without socket: company write fails closed"
else fail "enabled marker without socket: company write fails closed" "rc=$RC err=$ERR"; fi

# Exercise both the default .hq/daemon path and HQ_REGISTRY_DIR's daemon path.
mkdir -p "$HOME/.hq/daemon"
ALLOW='{"id":1,"ok":true,"result":{"decision":"allow","reasons":[],"additionalContext":""}}'
start_stub "$HOME/.hq/daemon/hqd.sock" "$ALLOW"
printf '%s' "$WRITE_OTHER" | env -u HQ_HQD_SOCKET -u HQ_REGISTRY_DIR sh "$SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && grep -q '"op":"policy.check"' "$TMP/req"; then pass "default .hq/daemon/hqd.sock reaches hqd"
else fail "default .hq/daemon/hqd.sock reaches hqd" "rc=$RC err=$ERR"; fi
stop_stub

mkdir -p "$TMP/registry/daemon"
start_stub "$TMP/registry/daemon/hqd.sock" "$ALLOW"
printf '%s' "$WRITE_OTHER" | env -u HQ_HQD_SOCKET HQ_REGISTRY_DIR="$TMP/registry" sh "$SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && grep -q '"op":"policy.check"' "$TMP/req"; then pass "HQ_REGISTRY_DIR/daemon/hqd.sock reaches hqd"
else fail "HQ_REGISTRY_DIR/daemon/hqd.sock reaches hqd" "rc=$RC err=$ERR"; fi
stop_stub

mkdir -p "$TMP/no-perl-modules"
cat > "$TMP/no-perl-modules/perl" <<'NO_PERL_MODULES'
#!/bin/sh
exit 1
NO_PERL_MODULES
chmod +x "$TMP/no-perl-modules/perl"
printf '%s' "$WRITE_OTHERCO" | env PATH="$TMP/no-perl-modules:$PATH" \
  HQ_HQD_SHIM_REPORT_UNREACHABLE=1 HQ_HQD_SOCKET="$NOSOCK" \
  sh "$SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?
OUT=$(cat "$TMP/out")
ERR=$(cat "$TMP/err")
if [ "$RC" -eq 75 ] && [ -z "$OUT$ERR" ]; then pass "routing mode reports unavailable Perl modules for direct fallback"
else fail "routing mode reports unavailable Perl modules for direct fallback" "rc=$RC out=$OUT err=$ERR"; fi

printf 'true 0\n' >"$HOME/.hq/hq-anywhere-runtime.flag.cmp_123456"
run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "stale enabled cache: first company write still reaches fail-closed shim"
else fail "stale enabled cache: first company write still enforces" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: Write to companies/ blocks with one unreachable line"
else fail "absent socket: Write to companies/ blocks" "rc=$RC err=$ERR"; fi

PRETTY_WRITE='{
  "session_id": "s1",
  "hook_event_name": "PreToolUse",
  "cwd": "/tmp/foreign-repo",
  "tool_name": "Write",
  "tool_input": {"file_path": "companies/otherco/x.md"}
}'
run_shim "$NOSOCK" "$PRETTY_WRITE" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "multiline JSON payload: company write still blocks"
else fail "multiline JSON payload" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$WRITE_ABS"
if [ "$RC" -eq 2 ]; then pass "absent socket: absolute companies/ path blocks (event from payload)"
else fail "absent socket: absolute companies/ path blocks" "rc=$RC err=$ERR"; fi

RELATIVE_COMPANY_WRITE='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/HQ/companies/acme","tool_name":"Write","tool_input":{"file_path":"knowledge/file.md"}}'
run_shim "$NOSOCK" "$RELATIVE_COMPANY_WRITE" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: relative file write from a company cwd blocks"
else fail "relative company cwd write blocks" "rc=$RC err=$ERR"; fi

RELATIVE_SHELL_WRITE='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/HQ","tool_name":"Bash","tool_input":{"command":"cd companies && touch acme/file"}}'
run_shim "$NOSOCK" "$RELATIVE_SHELL_WRITE" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: shell writes after cd into a company block"
else fail "relative shell company write blocks" "rc=$RC err=$ERR"; fi

mkdir -p "$TMP/no-perl-path"
printf '%s' "$RELATIVE_SHELL_WRITE" | env PATH="$TMP/no-perl-path" \
  HQ_HQD_SOCKET="$NOSOCK" HOME="$HOME" HQ_COMPANY_UID="$HQ_COMPANY_UID" \
  /bin/sh "$SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl in PATH: relative shell company write fails closed"
else fail "no Perl in PATH: relative shell company write fails closed" "rc=$RC out=$OUT err=$ERR"; fi

# Codex registers one shim command for every hook event and does not pass the
# event as argv. Exercise that real invocation shape without Perl.
CODEX_SHIM="$TMP/codex-hook-shim.sh"
cp "$SHIM" "$CODEX_SHIM"
cp "$SHIM_DIR/hq-anywhere-runtime-flag.cjs" "$SHIM_DIR/hqd-hook-flag-cache-lib.sh" "$TMP/"
CODEX_ABS_WRITE='{"hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Write","tool_input":{"file_path":"/tmp/HQ/companies/acme/x.md"}}'
CODEX_REL_WRITE='{"hook_event_name" : "PreToolUse","cwd":"/tmp/HQ","tool_name":"Bash","tool_input":{"command":"cd companies && touch acme/x.md"}}'
CODEX_UNKNOWN_TOOL='{"cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
CODEX_UNKNOWN_COMPANY='{"cwd":"/tmp","command":"touch companies/acme/x.md"}'
CODEX_PRETOOL_EVENT_ONLY='{"hook_event_name":"PreToolUse","cwd":"/tmp"}'
CODEX_PRETOOL_EVENT_ONLY_SPACED='{"hook_event_name" : "PreToolUse","cwd":"/tmp"}'
CODEX_STOP='{"hook_event_name":"Stop","cwd":"/tmp","session_id":"s1"}'
CODEX_SESSION_START='{"hook_event_name":"SessionStart","cwd":"/tmp","session_id":"s1"}'
run_codex_no_perl() {
  _payload="$1"
  printf '%s' "$_payload" | env PATH="$TMP/no-perl-path" HOME="$HOME" \
    HQ_COMPANY_UID="$HQ_COMPANY_UID" HQ_HQD_SOCKET="$NOSOCK" \
    /bin/sh "$CODEX_SHIM" >"$TMP/out" 2>"$TMP/err"
  RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
}
run_codex_no_perl "$CODEX_ABS_WRITE"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex no-arg PreToolUse absolute companies write blocks"
else fail "no Perl, Codex no-arg PreToolUse absolute companies write blocks" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_REL_WRITE"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex no-arg PreToolUse relative cd companies write blocks"
else fail "no Perl, Codex no-arg PreToolUse relative cd companies write blocks" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_UNKNOWN_TOOL"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex unknown event with tool_name fails closed"
else fail "no Perl, Codex unknown event with tool_name fails closed" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_UNKNOWN_COMPANY"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex unknown event naming companies/ fails closed"
else fail "no Perl, Codex unknown event naming companies/ fails closed" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_PRETOOL_EVENT_ONLY"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex event-only PreToolUse blocks without whitespace"
else fail "no Perl, Codex event-only PreToolUse blocks without whitespace" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_PRETOOL_EVENT_ONLY_SPACED"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex event-only PreToolUse blocks with whitespace around colon"
else fail "no Perl, Codex event-only PreToolUse with whitespace around colon" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_STOP"
if [ "$RC" -eq 0 ]; then pass "no Perl, Codex no-arg Stop passes"
else fail "no Perl, Codex no-arg Stop passes" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_SESSION_START"
if [ "$RC" -eq 0 ]; then pass "no Perl, Codex no-arg SessionStart passes"
else fail "no Perl, Codex no-arg SessionStart passes" "rc=$RC out=$OUT err=$ERR"; fi

perl -MJSON::PP -e 'print JSON::PP->new->encode({session_id=>"large",hook_event_name=>"PreToolUse",cwd=>"/tmp/HQ",tool_name=>"Write",tool_input=>{file_path=>"companies/acme/large.md",content=>"x" x 140000}})' >"$TMP/large-company-write.json"
HQ_HQD_SOCKET="$NOSOCK" sh "$SHIM" PreToolUse <"$TMP/large-company-write.json" >"$TMP/out" 2>"$TMP/err"
RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then pass "large company-write payload over 128 KiB blocks"
else fail "large company-write payload over 128 KiB blocks" "rc=$RC out=${#OUT} err=$ERR"; fi

run_shim "$NOSOCK" "$BASH_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ]; then pass "absent socket: Bash naming companies/ blocks"
else fail "absent socket: Bash naming companies/ blocks" "rc=$RC"; fi

run_shim "$NOSOCK" "$EXEC_CMD_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: exec_command cmd writing companies/ blocks"
else fail "absent socket: exec_command cmd writing companies/ blocks" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$WRITE_OTHER" PreToolUse
if [ "$RC" -eq 0 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: non-company write allowed, still not silent"
else fail "absent socket: non-company write allowed" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$READ_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: Read of companies/ allowed with the line"
else fail "absent socket: Read allowed" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$START" SessionStart
if [ "$RC" -eq 0 ] && [ "$ERR" = "$UNREACHABLE" ] && printf '%s' "$OUT" | grep -q 'bound to company: personal'; then
  pass "absent socket: SessionStart binds personal"
else fail "absent socket: SessionStart binds personal" "rc=$RC out=$OUT err=$ERR"; fi

run_shim "$NOSOCK" "$PROMPT" UserPromptSubmit
if [ "$RC" -eq 0 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: UserPromptSubmit passes with the line"
else fail "absent socket: UserPromptSubmit" "rc=$RC err=$ERR"; fi

SOCK="$TMP/stub.sock"
start_stub "$SOCK" hang
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ "$el" -lt 1500 ]; then pass "hung daemon: times out (${el}ms) and blocks the company write"
else fail "hung daemon: times out and blocks" "rc=$RC err=$ERR elapsed=${el}ms"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"decision":"block","reasons":["BLOCKED: Cross-company scope violation"],"additionalContext":""}}'
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'Cross-company scope violation'; then pass "stub block: exit 2 with reasons on stderr"
else fail "stub block" "rc=$RC err=$ERR"; fi
if grep -q '"op":"policy.check"' "$TMP/req" && grep -q '"sessionId":"s1"' "$TMP/req" && grep -q '"cwd":"/tmp/foreign-repo"' "$TMP/req"; then
  pass "PreToolUse forwards policy.check with sessionId and cwd"
else fail "PreToolUse request shape" "$(cat "$TMP/req")"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"decision":"allow","reasons":[],"additionalContext":"Policy X applies"}}'
run_shim "$SOCK" "$WRITE_OTHER" PreToolUse --runtime codex
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | grep -q '"additionalContext":"Policy X applies"' && printf '%s' "$OUT" | grep -q '"hookEventName":"PreToolUse"'; then
  pass "stub allow: additionalContext in hookSpecificOutput"
else fail "stub allow context" "rc=$RC out=$OUT err=$ERR"; fi
if grep -q '"runtime":"codex"' "$TMP/req"; then pass "--runtime codex is forwarded"
else fail "--runtime codex is forwarded" "$(cat "$TMP/req")"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"additionalContext":"missing decision"}}'
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qi 'policy check failed'; then pass "missing policy decision fails closed for company writes"
else fail "missing policy decision fails closed" "rc=$RC err=$ERR"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"decision":"permit","additionalContext":"unknown decision"}}'
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qi 'policy check failed'; then pass "unknown policy decision fails closed for company writes"
else fail "unknown policy decision fails closed" "rc=$RC err=$ERR"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":false,"error":{"code":"bad_args","message":"company is required"}}'
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ]; then pass "daemon error on a company write fails closed"
else fail "daemon error on a company write fails closed" "rc=$RC err=$ERR"; fi
run_shim "$SOCK" "$WRITE_OTHER" PreToolUse
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -q 'company is required'; then pass "daemon error on other writes allows and reports"
else fail "daemon error on other writes" "rc=$RC err=$ERR"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"runtime":"claude","sessionId":"s1","cwd":"/tmp/foreign-repo","company":"indigo"}}'
run_shim "$SOCK" "$START" SessionStart
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'bound to company: indigo' && grep -q '"op":"session.open"' "$TMP/req"; then
  pass "SessionStart sends session.open and reports the bound company"
else fail "SessionStart session.open" "rc=$RC out=$OUT req=$(cat "$TMP/req")"; fi
stop_stub


printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
