#!/usr/bin/env bash
# Pack tests for hq-pack-booking. Runs on any OS with Node.js 22.6+ and npm.
#
# 1. Installs the template's dependencies, runs its typecheck and unit tests
#    (schema, validator, availability engine, booking API, stores, providers,
#    dev server; line coverage must stay >= 90%), then stages a deploy copy.
# 2. Exercises scripts/hq-booking.sh against a fake HQ root with two companies
#    and a stub `hq` CLI that reports the session company.
# 3. tests/launcher-flows.sh: setup, hosts, build, deploy (fake hq-deploy
#    API), dev, owner and agent (a local dev instance), and the cross-company
#    and owner-key checks for each.
#
# The real install into an HQ tree is covered by tests/e2e-install.sh.
# No -e: every check runs and failures are counted, then the exit code reports them.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pack="$(cd "$here/.." && pwd)"

pass=0
failures=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { failures=$((failures + 1)); printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '     %s\n' "$2" >&2; return 0; }

node_v="$(node -p 'process.versions.node' 2>/dev/null || true)"
[ -n "$node_v" ] || { echo "FAIL node is required" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- 1. template typecheck + unit tests ------------------------------------
cp -R "$pack/template" "$tmp/template-ci"
rm -rf "$tmp/template-ci/node_modules"
(cd "$tmp/template-ci" && npm ci --no-audit --no-fund --loglevel=error) >/dev/null
# knowledge/ sits beside template/ in the pack; the config tests read the examples from there.
mkdir -p "$tmp/knowledge" && cp -R "$pack/knowledge/booking" "$tmp/knowledge/booking"
if (cd "$tmp/template-ci" && npm run --silent typecheck); then ok "template typecheck"; else bad "template typecheck"; fi
if out="$(cd "$tmp/template-ci" && npm test --silent 2>&1)"; then
  ok "template unit tests and coverage"
else
  bad "template unit tests and coverage" "$(printf '%s' "$out" | grep -E '✖|not ok|coverage threshold|Error' | head -20)"
fi
# The deploy stage: a self-contained api/ + db/migrations/ for hq-deploy's app type.
if out="$(cd "$tmp/template-ci" && node --experimental-strip-types --no-warnings dev/stage.ts "$pack/knowledge/booking/examples/sales-round-robin.yaml" "$tmp/stage-out" 2>&1)" \
  && printf '%s' "$out" | grep -q '"ok":true' && [ -f "$tmp/stage-out/api/_lib/shared/availability.ts" ] && [ -f "$tmp/stage-out/db/migrations/001_create_bookings.sql" ]; then
  ok "deploy stage is self-contained"
else
  bad "deploy stage is self-contained" "$out"
fi

# --- 2. launcher ---------------------------------------------------------------
mkdir -p "$tmp/pack"
cp -R "$pack/scripts" "$pack/knowledge" "$tmp/pack/"
cp -R "$tmp/template-ci" "$tmp/pack/template" # reuse installed deps
L="$tmp/pack/scripts/hq-booking.sh"

hq="$tmp/hq"
mkdir -p "$hq/companies/acme/booking" "$hq/companies/other/booking" "$tmp/bin"
printf 'companies:\n  acme:\n    name: Acme\n  other:\n    name: Other\n' >"$hq/companies/manifest.yaml"
# Stub `hq`: the session company, a file-backed vault (values never printed),
# and the member list. TEST_VAULT_FAIL=1 makes `secrets set` fail;
# TEST_MEMBERS_FAIL=1 makes `members list` unavailable.
mkdir -p "$tmp/vault" "$tmp/members"
cat >"$tmp/bin/hq" <<'EOF'
#!/usr/bin/env bash
vault="$TEST_VAULT_DIR"
if [ "$*" = "core hq-session get company_slug" ]; then printf '%s' "${TEST_SESSION_COMPANY:-}"; exit 0; fi
if [ "${1:-}" = "secrets" ] && [ "${2:-}" = "--company" ]; then
  co="$3"; sub="$4"; name="$5"
  case "$sub" in
    exists) [ -f "$vault/$co/$name" ] && exit 0; exit 1 ;;
    set)
      [ "${6:-}" = "--from-stdin" ] || exit 64
      [ "${TEST_VAULT_FAIL:-}" = "1" ] && { echo "Error: not signed in" >&2; exit 1; }
      mkdir -p "$vault/$co"; cat >"$vault/$co/$name"; echo "Secret $name saved." >&2; exit 0 ;;
  esac
  exit 9
fi
if [ "${1:-}" = "secrets" ] && [ "${2:-}" = "exec" ]; then
  shift 2; only=""; co=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in --only) only="$2"; shift 2 ;; --company) co="$2"; shift 2 ;; *) exit 64 ;; esac
  done
  shift
  [ -f "$vault/$co/$only" ] || { echo "Error: secret $only not found" >&2; exit 1; }
  export "$only=$(cat "$vault/$co/$only")"
  exec "$@"
fi
if [ "${1:-}" = "members" ] && [ "${2:-}" = "--company" ] && [ "${4:-}" = "list" ]; then
  [ "${TEST_MEMBERS_FAIL:-}" = "1" ] && { echo "error: unknown command 'members'" >&2; exit 1; }
  printf 'EMAIL                ROLE\n'; cat "$TEST_MEMBERS_DIR/$3" 2>/dev/null; exit 0
fi
exit 9
EOF
chmod +x "$tmp/bin/hq"
export PATH="$tmp/bin:$PATH" HQ_ROOT="$hq" TEST_VAULT_DIR="$tmp/vault" TEST_MEMBERS_DIR="$tmp/members"
ALL_OUT="$tmp/all-output.log"
: >"$ALL_OUT"

run() { # expected-exit name cmd...
  local want="$1" name="$2" got=0
  shift 2
  OUT="$("$@" 2>"$tmp/stderr")" || got=$?
  { printf '%s\n' "$OUT"; cat "$tmp/stderr"; } >>"$ALL_OUT"
  if [ "$got" -ne "$want" ]; then bad "$name (exit $got, want $want)" "$OUT $(cat "$tmp/stderr")"; return 1; fi
  if ! printf '%s' "$OUT" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' 2>/dev/null; then bad "$name (output is not one JSON object)" "$OUT"; return 1; fi
  ok "$name"
}
has() { # name needle
  case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1" "missing $2 in: $OUT" ;; esac
}
hasnt() {
  case "$OUT" in *"$2"*) bad "$1" "unexpected $2 in: $OUT" ;; *) ok "$1" ;; esac
}

export TEST_SESSION_COMPANY=acme
run 0 "doctor" bash "$L" doctor && has "doctor reports deps installed" '"depsInstalled":true'
run 0 "path before setup" bash "$L" path && has "path points at the company file" "/companies/acme/booking/booking.yaml" && has "path says missing" '"exists":false'
run 1 "validate with no file yet" bash "$L" validate && has "no-config error" '"error":"no-config"'

for ex in "$pack"/knowledge/booking/examples/*.yaml; do
  name="$(basename "$ex" .yaml)"
  cp "$ex" "$hq/companies/acme/booking/booking.yaml"
  run 0 "validate example $name" bash "$L" validate
done
has "validate reports event types" '"eventTypes":['

cat >"$hq/companies/acme/booking/booking.yaml" <<'EOF'
version: 1
company: acme
timezone: America/New_York
hosts:
  - { id: ana, name: Ana, email: ana@acme.example, hours: { mon: ["09:00-17:00"] } }
  - { id: ben, name: Ben, email: ben@acme.example, hours: { mon: ["09:00-17:00"] } }
eventTypes:
  - id: panel
    title: Panel
    kind: collective
    hosts: [ana, ben]
    durations: [30]
    seats: 4
    locations: [{ type: meet }]
EOF
run 1 "collective with seats is rejected" bash "$L" validate && has "names the field" '"path":"eventTypes[0].seats"' && has "names the error" '"code":"seats-not-allowed"'

cat >"$hq/companies/acme/booking/booking.yaml" <<'EOF'
version: 1
company: acme
timezone: America/New_York
hosts:
  - id: ana
    name: Ana
    email: ana@acme.example
    hours: { mon: ["09:00-17:00"] }
    calendars:
      conflicts:
        - { source: ical, secret: "webcal://calendar.example/private-feed-token-123" }
eventTypes:
  - { id: intro, title: Intro, kind: round-robin, hosts: [ana], durations: [30], locations: [{ type: meet }] }
EOF
run 1 "pasted iCal link and one-host round-robin are rejected" bash "$L" validate
has "secret-is-url error" '"code":"secret-is-url"'
has "round-robin error" '"code":"round-robin-needs-two-hosts"'
hasnt "the link is not echoed back" "private-feed-token-123"

printf 'version: 1\ncompany: [\n' >"$hq/companies/acme/booking/booking.yaml"
run 1 "broken YAML" bash "$L" validate && has "yaml-syntax error" '"code":"yaml-syntax"'

cp "$pack/knowledge/booking/examples/class-with-seats.yaml" "$hq/companies/other/booking/booking.yaml"
run 1 "another company's file is refused" bash "$L" validate "$hq/companies/other/booking/booking.yaml" && has "other-company error" '"error":"other-company"'
ln -s "$hq/companies/other/booking/booking.yaml" "$tmp/sneaky.yaml"
run 1 "a symlink into another company is refused" bash "$L" validate "$tmp/sneaky.yaml"

cp "$pack/knowledge/booking/examples/sales-round-robin.yaml" "$hq/companies/acme/booking/booking.yaml"
run 0 "slots preview" bash "$L" slots --event demo --now 2026-11-02T12:00:00Z --days 1 --tz Europe/London
has "slots have local times" '"local":"Mon, Nov 2'
has "round-robin slots name one host" '"hosts":["sam"]'
printf '{"sam":[{"start":"2026-11-02T15:00:00Z","end":"2026-11-02T23:00:00Z"}],"priya":[{"start":"2026-11-02T16:00:00Z","end":"2026-11-03T00:00:00Z"}]}' >"$tmp/busy.json"
run 0 "slots honor busy times" bash "$L" slots --event demo --now 2026-11-02T12:00:00Z --days 1 --busy "$tmp/busy.json"
has "nothing open when both are busy" '"count":0'
run 2 "slots with an unknown event" bash "$L" slots --event nope --now 2026-11-02T12:00:00Z
run 2 "slots with a duration not offered" bash "$L" slots --event demo --duration 45
run 2 "slots with a bad time zone" bash "$L" slots --event demo --tz Mars/Base

export TEST_SESSION_COMPANY=""
run 1 "no session company is refused" bash "$L" validate && has "no-company error" '"error":"no-company"'
export TEST_SESSION_COMPANY="../other"
run 1 "a bad company slug is refused" bash "$L" validate && has "bad-company error" '"error":"bad-company"'
export TEST_SESSION_COMPANY=acme

run 2 "unknown command" bash "$L" publish
run 2 "validate with two files" bash "$L" validate a b

# Not named *.test.sh: CI runs those on their own, and this one is sourced.
# shellcheck source=launcher-flows.sh
. "$here/launcher-flows.sh"

printf '\n%d passed, %d failed\n' "$pass" "$failures"
[ "$failures" -eq 0 ]
