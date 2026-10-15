# Launcher flows: setup, hosts, build, deploy, dev, owner and agent. Sourced by
# booking.test.sh after its launcher checks, so it shares run/has/hasnt, the
# fake HQ root ($hq, companies acme and other), the stub hq CLI with its
# file-backed vault, and the pack copy at $tmp/pack ($L is its launcher).
#
# - owner and agent commands run against a local dev instance of the app
#   (`hq-booking.sh dev` on a free port, started and stopped here);
# - deploy runs against tests/fixtures/fake-deploy-api.mjs through the /deploy
#   skill's helper scripts: the real ones when this pack sits inside an HQ tree
#   with jq installed, otherwise the stand-ins in tests/fixtures/deploy-scripts/.
#   identity-resolve.sh is always the stand-in (no sign-in is touched).

DEV_PID=""
API_PID=""
trap '[ -n "$DEV_PID" ] && kill "$DEV_PID" 2>/dev/null; [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null; rm -rf "$tmp"' EXIT

jget() { # js-path -> value from $OUT (objects as JSON)
  printf '%s' "$OUT" | node -e '
    const o = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const v = process.argv[1].split(".").filter(Boolean).reduce((a, k) => (a == null ? a : a[k]), o);
    process.stdout.write(v === undefined ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));' "$1"
}
yhash() { node -e 'const m=/ownerKeySha256:\s*"?([0-9a-f]{64})/.exec(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m?m[1]:"")' "$1"; }
sha() { node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$1"; }

acme="$hq/companies/acme/booking"
other="$hq/companies/other/booking"
key_file="$tmp/vault/acme/BOOKING_OWNER_KEY"
export TEST_SESSION_COMPANY=acme
rm -f "$acme/booking.yaml"
cp "$pack/knowledge/booking/examples/class-with-seats.yaml" "$other/booking.yaml"
printf 'ana@acme.example     member\nben@acme.example     admin\n' >"$tmp/members/acme"

# --- setup ---------------------------------------------------------------------
run 1 "setup refuses an example from another company's folder" bash "$L" setup --from "$other/booking.yaml" && has "names the refusal" '"error":"other-company"'
[ ! -f "$acme/booking.yaml" ] && ok "nothing written after the refusal" || bad "nothing written after the refusal"
run 1 "setup refuses --company for another company" bash "$L" setup --company other && has "other-company on --company" '"error":"other-company"'
run 2 "setup with an unknown example" bash "$L" setup --from nope

TEST_VAULT_FAIL=1 run 1 "setup stops when the vault write fails" bash "$L" setup
has "vault-write-failed" '"error":"vault-write-failed"'
[ -z "$(yhash "$acme/booking.yaml")" ] && ok "no key hash written without a vault key" || bad "no key hash written without a vault key"

run 0 "setup creates booking.yaml and the owner key" bash "$L" setup --company acme --company-name "Acme Inc"
has "owner key created" '"ownerKey":"created"'
has "provider is sandbox" '"provider":"sandbox"'
has "says what to do next" '"next":['
grep -q '^company: acme' "$acme/booking.yaml" && ok "company slug filled in" || bad "company slug filled in"
[ -s "$key_file" ] && ok "owner key stored in the vault" || bad "owner key stored in the vault"
KEY1="$(cat "$key_file")"
[ "${#KEY1}" -eq 43 ] && ok "owner key is 32 random bytes in base64url" || bad "owner key is 32 random bytes in base64url" "length ${#KEY1}"
[ "$(yhash "$acme/booking.yaml")" = "$(printf '%s' "$KEY1" | node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(0)).digest("hex"))')" ] \
  && ok "booking.yaml holds the key's SHA-256" || bad "booking.yaml holds the key's SHA-256"
run 0 "booking.yaml from setup validates" bash "$L" validate

run 0 "setup again keeps the key" bash "$L" setup && has "kept" '"ownerKey":"kept"'
[ "$(cat "$key_file")" = "$KEY1" ] && ok "vault key unchanged" || bad "vault key unchanged"
run 0 "setup --rotate-owner-key" bash "$L" setup --rotate-owner-key && has "rotated" '"ownerKey":"rotated"'
KEY="$(cat "$key_file")"
[ "$KEY" != "$KEY1" ] && ok "rotation makes a new key" || bad "rotation makes a new key"
[ "$(yhash "$acme/booking.yaml")" = "$(printf '%s' "$KEY" | node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(0)).digest("hex"))')" ] \
  && ok "rotation updates the hash" || bad "rotation updates the hash"

# --- hosts ---------------------------------------------------------------------
run 0 "hosts list" bash "$L" hosts list && has "lists the example host" '"id":"alex"' && has "sandbox hosts are booking ready" '"bookingReady":true'
before="$(sha "$acme/booking.yaml")"
run 1 "adding a second host to a one-on-one is refused" bash "$L" hosts add --email ana@acme.example --event-types intro-call
has "invalid-change" '"error":"invalid-change"' && has "names the rule" 'one-on-one-needs-one-host'
[ "$(sha "$acme/booking.yaml")" = "$before" ] && ok "refused change leaves the file alone" || bad "refused change leaves the file alone"
run 0 "hosts add a member" bash "$L" hosts add --email ana@acme.example --name "Ana Diaz" --timezone Europe/Madrid
has "membership checked" '"membership":"checked"' && has "booking ready in sandbox" '"bookingReady":true' && has "real flow DM noted" 'sends ana@acme.example a DM with a connect link'
run 1 "hosts add a non-member is refused" bash "$L" hosts add --email eve@outside.example && has "not-a-member" '"error":"not-a-member"'
TEST_MEMBERS_FAIL=1 run 0 "hosts add when the member list is unavailable" bash "$L" hosts add --email ben@acme.example
has "says the check was unavailable" '"membership":"unavailable"'
run 1 "hosts add twice" bash "$L" hosts add --email ana@acme.example && has "already-host" '"error":"already-host"'
run 0 "hosts remove" bash "$L" hosts remove ben && has "removed ben" '"removed":"ben"' && has "existing bookings stay" 'Existing bookings stay'
run 1 "removing the only host of an event type is refused" bash "$L" hosts remove alex
run 0 "booking.yaml still validates after host edits" bash "$L" validate
run 1 "hosts with --company other" bash "$L" hosts list --company other

# --- build -------------------------------------------------------------------------
# The booking pages have their own tests; here `npm run build` is a stand-in that
# proves the launcher passes BOOKING_OVERRIDES_DIR and stages dist/.
cp "$here/fixtures/stub-ui-build.mjs" "$tmp/pack/template/stub-ui-build.mjs"
node -e 'const f=process.argv[1],fs=require("fs"),p=JSON.parse(fs.readFileSync(f,"utf8"));p.scripts.build="node stub-ui-build.mjs";fs.writeFileSync(f,JSON.stringify(p,null,2))' "$tmp/pack/template/package.json"
mkdir -p "$acme/overrides"
printf 'ACME OVERRIDE HEADER\n' >"$acme/overrides/Header.tsx"
stage="$hq/workspace/booking-builds/acme/stage"
run 0 "build" bash "$L" build
has "reports the stage dir" '/hq/workspace/booking-builds/acme/stage"' && has "reports the overrides" '/booking/overrides"'
files="$(jget files)"
[ -n "$files" ] && [ "$files" -le 100 ] && ok "file count under the cap ($files)" || bad "file count under the cap" "$files"
grep -q 'ACME OVERRIDE HEADER' "$stage/dist/index.html" && ok "overrides reach the build" || bad "overrides reach the build"
[ -f "$stage/api/_lib/booking.config.json" ] && grep -q '"company": "acme"' "$stage/api/_lib/booking.config.json" && ok "checked config is bundled" || bad "checked config is bundled"
[ -f "$stage/db/migrations/001_create_bookings.sql" ] && ok "migrations staged" || bad "migrations staged"
TEST_UI_FILES=120 run 1 "build over the 100-file cap is refused" bash "$L" build && has "too-many-files" '"error":"too-many-files"'
mv "$acme/overrides" "$tmp/acme-overrides"
ln -s "$hq/companies/other" "$acme/overrides"
run 1 "overrides linked to another company are refused" bash "$L" build && has "other-company for overrides" '"error":"other-company"'
rm "$acme/overrides"
mv "$tmp/acme-overrides" "$acme/overrides"
run 0 "build again" bash "$L" build

# --- deploy (fake hq-deploy API) -----------------------------------------------------
scripts_dst="$hq/.claude/skills/deploy/scripts"
mkdir -p "$scripts_dst"
real_scripts=""
d="$pack"
while [ "$d" != "/" ]; do
  [ -f "$d/.claude/skills/deploy/scripts/deploy-api-request.sh" ] && { real_scripts="$d/.claude/skills/deploy/scripts"; break; }
  d="$(dirname "$d")"
done
if [ -n "$real_scripts" ] && command -v jq >/dev/null 2>&1 && [ "${BOOKING_TEST_STUB_DEPLOY:-}" != "1" ]; then
  for s in deploy-api-request.sh guardrails-check.sh resolve-deploy-api.sh password-helper.sh; do cp "$real_scripts/$s" "$scripts_dst/$s"; done
  printf 'note deploy uses the real /deploy helper scripts from %s\n' "$real_scripts"
else
  for s in deploy-api-request.sh guardrails-check.sh resolve-deploy-api.sh password-helper.sh; do cp "$here/fixtures/deploy-scripts/$s" "$scripts_dst/$s"; done
  printf 'note deploy uses the stand-in helper scripts\n'
fi
cp "$here/fixtures/deploy-scripts/identity-resolve.sh" "$scripts_dst/identity-resolve.sh"
chmod +x "$scripts_dst"/*.sh
node "$here/fixtures/fake-deploy-api.mjs" "$tmp/api.port" "$tmp/api.log" &
API_PID=$!
for _ in $(seq 1 50); do [ -s "$tmp/api.port" ] && break; sleep 0.1; done
dlog="$tmp/api.log"
: >"$dlog"
export HQ_DEPLOY_API="http://127.0.0.1:$(cat "$tmp/api.port")" HQ_DEPLOY_DOMAIN="invalid" HQ_DB_BILLING_EXEMPT_ORGS="indigo"
dep() { HOME="$tmp/home" run "$@"; }
reqs() { node -e 'console.log(require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(l=>{const e=JSON.parse(l);return e.method+" "+e.path.replace(/app_\d+/,":id")}).join(","))' "$dlog"; }

TEST_IDENTITY=login_required dep 1 "deploy when signed out" bash "$L" deploy --accept-database-billing && has "login-required" '"error":"login-required"'
dep 1 "deploy without accepting database billing stops" bash "$L" deploy
has "database terms in plain words" 'costs $10 a month' && has "billing error code" '"error":"database-billing-ack-required"'
[ "$(reqs)" = "GET /api/apps" ] && ok "nothing created before the billing answer" || bad "nothing created before the billing answer" "$(reqs)"
: >"$dlog"
dep 0 "deploy with --accept-database-billing" bash "$L" deploy --accept-database-billing
has "live URL" '"url":"https://booking-acme.invalid"' && has "password access by default" '"access":"password"' && has "password shown once" '"password":"'
PW="$(jget password)"
want="GET /api/apps,POST /api/apps,GET /api/apps/:id,PATCH /api/apps/:id,POST /api/apps/:id/access-mode,POST /api/apps/:id/deploy"
[ "$(reqs)" = "$want" ] && ok "deploy request sequence" || bad "deploy request sequence" "$(reqs)"
grep -q '"databaseBillingAcknowledged":true' "$dlog" && ok "database enabled with the acknowledgement" || bad "database enabled with the acknowledgement"
grep '/deploy"' "$dlog" | grep -q '"type":true,"ack":true,"file":true' && ok "app upload is multipart type=app with the ack" || bad "app upload is multipart type=app with the ack" "$(grep '/deploy"' "$dlog")"
grep -q '"mode":"password"' "$dlog" && ok "password gate set before the upload" || bad "password gate set before the upload"
node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);process.exit(l.every(e=>e.auth&&e.org==="acme")?0:1)' "$dlog" && ok "every request is signed in and scoped to acme" || bad "every request is signed in and scoped to acme"
[ -f "$acme/deploy.json" ] && grep -q '"url": "https://booking-acme.invalid"' "$acme/deploy.json" && ok "deploy.json records the URL" || bad "deploy.json records the URL"
grep -q '"booking-acme"' "$tmp/home/.hq/deploy-passwords.json" 2>/dev/null && ok "password saved for the deploy skill" || bad "password saved for the deploy skill"
: >"$dlog"
dep 0 "redeploy" bash "$L" deploy
has "redeploy keeps the password" 'existing password was kept' && hasnt "no new password" '"password":"'
[ "$(reqs)" = "GET /api/apps,GET /api/apps/:id,POST /api/apps/:id/deploy" ] && ok "redeploy only uploads" || bad "redeploy only uploads" "$(reqs)"
: >"$dlog"
dep 0 "deploy --access public" bash "$L" deploy --access public && has "public warning" '"warning":"The pages are public'
grep -q '"mode":"public"' "$dlog" && ok "public access set" || bad "public access set"
dep 2 "deploy --password with public access" bash "$L" deploy --access public --password longenough
dep 2 "deploy with a short password" bash "$L" deploy --password short
dep 1 "deploy --company other" bash "$L" deploy --company other && has "deploy other-company" '"error":"other-company"'

# A new app name is a config change: the old build is stale. Exempt companies
# get the database without a question.
node -e 'const f=process.argv[1],fs=require("fs");fs.writeFileSync(f,fs.readFileSync(f,"utf8").replace("prototype:\n","prototype:\n  appName: acme-meetings\n"))' "$acme/booking.yaml"
grep -q 'appName: acme-meetings' "$acme/booking.yaml" && ok "app name set in booking.yaml" || bad "app name set in booking.yaml"
dep 1 "deploy after a config change needs a rebuild" bash "$L" deploy && has "build-stale" '"error":"build-stale"'
run 0 "rebuild" bash "$L" build
: >"$dlog"
HQ_DB_BILLING_EXEMPT_ORGS="indigo,acme" dep 0 "deploy for an exempt company sends the ack without asking" bash "$L" deploy
has "custom app name" '"appName":"acme-meetings"' && has "free database line" 'The database is free for this company.'
grep -q '"databaseBillingAcknowledged":true' "$dlog" && ok "exempt deploy acknowledges billing" || bad "exempt deploy acknowledges billing"
kill "$API_PID" 2>/dev/null
API_PID=""

# --- dev instance + owner commands ------------------------------------------------------
run 1 "dev with --company other" bash "$L" dev --company other
bash "$L" dev --port 0 >"$tmp/dev.out" 2>"$tmp/dev.err" &
DEV_PID=$!
for _ in $(seq 1 100); do grep -q '"url"' "$tmp/dev.out" 2>/dev/null && break; sleep 0.1; done
OUT="$(head -1 "$tmp/dev.out")"
DEV="$(jget url)"
case "$DEV" in http://127.0.0.1:*) ok "dev instance is listening at $DEV" ;; *) bad "dev instance is listening" "$(cat "$tmp/dev.out" "$tmp/dev.err")" ;; esac
cat "$tmp/dev.out" "$tmp/dev.err" >>"$ALL_OUT"

o() { run "$1" "$2" bash "$L" owner "${@:3}" --url "$DEV"; }
o 0 "owner session" session && has "owner session is sandbox" '"sandbox":true'
mk="$(node -e '
  const base = process.argv[1];
  const j = (p, b) => fetch(base + p, b ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(b) } : undefined).then((r) => r.json());
  (async () => {
    const s = await j("/api/slots?eventType=intro-call&duration=30");
    const h = await j("/api/holds", { eventType: "intro-call", start: s.slots[0].start, duration: 30 });
    const b = await j("/api/bookings", { holdId: h.holdId, name: "Iris Invitee", email: "iris@client.example", answers: { company: "Client Co" } });
    console.log(JSON.stringify({ id: b.booking.id, next: s.slots[8].start }));
  })().catch((e) => { console.log(JSON.stringify({ error: String(e) })); });' "$DEV")"
BID="$(OUT="$mk" jget id)"
NEXT="$(OUT="$mk" jget next)"
[ -n "$BID" ] && ok "a visitor booked through the public API" || bad "a visitor booked through the public API" "$mk"

o 0 "owner bookings" bookings --days 60 && has "lists the booking" "\"id\":\"$BID\"" && has "plain lines" '"lines":["'
has "line names the invitee" 'Iris Invitee <iris@client.example>'
o 0 "owner booking <id>" booking "$BID" && has "audit trail" '"audit":['
o 0 "owner reschedule" reschedule "$BID" --start "$NEXT" && has "moved" "\"start\":\"$NEXT\""
o 2 "owner reschedule without --start" reschedule "$BID"
o 1 "owner no-show before the meeting" no-show "$BID" && has "not-started" '"error":"not-started"'
o 0 "owner link" link --event intro-call --expires 48 && has "single-use link URL" "\"url\":\"$DEV/l/"
o 0 "owner times" times --event intro-call --tz Europe/London --days 14
snippet="$(jget snippet)"
case "$snippet" in
  "Here are some times that work for a 30-minute Intro call (times are "*"(Europe/London)):"*"- "*"day, "*"Pick one of these, or any other open time, here: $DEV/intro-call"*)
    ok "owner times prints a readable snippet" ;;
  *) bad "owner times prints a readable snippet" "$snippet" ;;
esac
printf '%s' "$snippet" | grep -Eq '^- [A-Z][a-z]+day, [A-Z][a-z]+ [0-9]+: [0-9]{1,2}:[0-9]{2} (AM|PM)' && ok "snippet lines read like an email" || bad "snippet lines read like an email" "$snippet"
o 0 "owner times with a minted link" times --event intro-call --link && has "snippet uses the link" "here: $DEV/l/"
o 2 "owner times with a bad zone" times --event intro-call --tz Mars/Base
o 0 "owner analytics" analytics && has "totals" '"totals":{'
o 0 "owner outbox" outbox && has "sandbox outbox" 'stored in the app, not sent' && has "confirmation email" '"kind":"confirmation"'
o 0 "owner notifications" notifications && has "notifications list" '"notifications":['
o 0 "owner webhooks" webhooks && has "webhooks list" '"webhooks":['
o 0 "owner jobs-run" jobs-run && has "jobs ran" '"ranAt":"'
o 0 "owner agent-key" agent-key --member bob@other.example --name "Bob Other" --member-company other --max-duration 60
AGENT_KEY="$(jget key)"
AGENT_ID="$(jget agentKey.id)"
has "delegation on" '"enabled":true' && has "limits stored" '"maxDuration":60' && has "shown once note" 'shown once'
[ -n "$AGENT_KEY" ] && ok "agent key printed once" || bad "agent key printed once"
o 0 "owner agents" agents && has "agent listed with delegation" '"memberId":"bob"' && hasnt "agent key not listed again" "$AGENT_KEY"
o 1 "owner cancel an unknown booking" cancel bk_nope
o 2 "owner unknown command" frobnicate
run 1 "owner key never goes to another company's app" bash "$L" owner bookings --url https://booking-other.indigo-hq.com && has "other-app" '"error":"other-app"'
run 1 "owner with --company other" bash "$L" owner bookings --company other --url "$DEV"

# --- agent-to-agent (bob at other books with acme) -------------------------------------
mkdir -p "$tmp/vault/other"
printf '%s' "$AGENT_KEY" >"$tmp/vault/other/BOOKING_AGENT_KEY_ACME"
export TEST_SESSION_COMPANY=other
run 1 "agent with no key in the vault" bash "$L" agent times acme/intro-call --key-secret NOPE_KEY --url "$DEV" && has "no-agent-key" '"error":"no-agent-key"'
run 0 "agent event-types" bash "$L" agent event-types acme --url "$DEV" && has "outside company asks first" '"mode":"ask"'
run 0 "agent times" bash "$L" agent times acme/intro-call --url "$DEV" --tz America/Chicago
has "coarse offers" '"coarse":true' && has "agent snippet" 'Here are some times'
n_offers="$(printf '%s' "$OUT" | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0,"utf8")).offers.length))')"
# The last offer is days away, clear of the 4-hour cancel cutoff used below.
OFFER="$(jget "offers.$((n_offers - 1)).start")"
[ "$n_offers" -ge 1 ] && [ "$n_offers" -le 4 ] && ok "at most four offers ($n_offers)" || bad "at most four offers" "$n_offers"
run 0 "agent book asks the host first" bash "$L" agent book acme/intro-call --start "$OFFER" --topic "Pricing" --url "$DEV"
has "pending approval" '"status":"pending-approval"'
run 1 "agent with --company acme from an other session" bash "$L" agent times acme/intro-call --company acme --url "$DEV"
export TEST_SESSION_COMPANY=acme
o 0 "owner approvals" approvals && has "pending request from bob" '"memberId":"bob"' && has "topic is untrusted" '"untrusted":true'
APPROVAL="$(jget approvals.0.id)"
o 0 "owner approve" approve "$APPROVAL" && has "approved" '"status":"approved"'
ABID="$(jget booking.id)"
o 1 "owner approve twice" approve "$APPROVAL"
o 0 "owner bookings shows the agent booking" bookings --days 60 && has "booked by line" "booked by"
export TEST_SESSION_COMPANY=other
run 0 "agent bookings" bash "$L" agent bookings acme --url "$DEV" && has "agent sees its booking" "\"id\":\"$ABID\""
run 0 "agent cancel its booking" bash "$L" agent cancel acme "$ABID" --url "$DEV" && has "canceled" '"status":"canceled"'
export TEST_SESSION_COMPANY=acme
o 0 "owner delegation pause" delegation bob --undo && has "paused" '"enabled":false'
export TEST_SESSION_COMPANY=other
run 1 "a paused member's agent is refused" bash "$L" agent times acme/intro-call --url "$DEV" && has "delegation-off" '"error":"delegation-off"'
export TEST_SESSION_COMPANY=acme
o 0 "owner delegation resume keeps the limits" delegation bob && has "resumed" '"enabled":true' && has "limits kept" '"maxDuration":60'
o 0 "owner delete-invitee" delete-invitee --email iris@client.example && has "redacted" '"redacted":'
o 0 "owner revoke-agent" revoke-agent "$AGENT_ID" && has "revoked" '"revoked":true'
export TEST_SESSION_COMPANY=other
run 1 "a revoked agent key stops working" bash "$L" agent times acme/intro-call --url "$DEV" && has "key-revoked" '"error":"key-revoked"'
export TEST_SESSION_COMPANY=acme

# --- cross-company and no-company refusals for every new command ---------------------------
for c in "setup" "build" "deploy" "dev" "owner bookings" "agent times acme/intro-call" "hosts list"; do
  # shellcheck disable=SC2086
  run 1 "$c with --company other is refused" bash "$L" $c --company other && has "$c names other-company" '"error":"other-company"'
done
export TEST_SESSION_COMPANY=""
for c in "setup" "build" "deploy" "dev" "owner bookings" "agent times acme/intro-call" "hosts list"; do
  # shellcheck disable=SC2086
  run 1 "$c with no session company is refused" bash "$L" $c && has "$c names no-company" '"error":"no-company"'
done
export TEST_SESSION_COMPANY=acme
mv "$acme/booking.yaml" "$tmp/acme-booking.yaml"
ln -s "$other/booking.yaml" "$acme/booking.yaml"
for c in "setup" "build" "deploy" "dev" "hosts list"; do
  # shellcheck disable=SC2086
  run 1 "$c refuses booking.yaml linked to another company" bash "$L" $c && has "$c link names other-company" '"error":"other-company"'
done
rm "$acme/booking.yaml"
mv "$tmp/acme-booking.yaml" "$acme/booking.yaml"
mv "$acme" "$tmp/acme-booking-dir"
ln -s "$other" "$acme"
for c in "setup" "owner bookings" "deploy"; do
  # shellcheck disable=SC2086
  run 1 "$c refuses a booking folder linked to another company" bash "$L" $c && has "$c folder names other-company" '"error":"other-company"'
done
rm "$acme"
mv "$tmp/acme-booking-dir" "$acme"

# --- the owner key never leaks ---------------------------------------------------------------
kill "$DEV_PID" 2>/dev/null
DEV_PID=""
for k in "$KEY1" "$KEY"; do
  if grep -qF -- "$k" "$ALL_OUT"; then bad "owner key absent from every command's stdout and stderr"; else ok "owner key absent from every command's stdout and stderr"; fi
  if grep -qF -- "$k" "$acme/booking.yaml"; then bad "owner key absent from booking.yaml"; else ok "owner key absent from booking.yaml"; fi
  if grep -qF -- "$k" "$acme/deploy.json"; then bad "owner key absent from deploy.json"; else ok "owner key absent from deploy.json"; fi
  if grep -rqF -- "$k" "$hq/workspace"; then bad "owner key absent from the build folder"; else ok "owner key absent from the build folder"; fi
done
{ grep -qE 'test-jwt|test-id-token' "$acme/deploy.json" || { [ -n "$PW" ] && grep -qF -- "$PW" "$acme/deploy.json"; }; } && bad "deploy.json holds no tokens or passwords" || ok "deploy.json holds no tokens or passwords"
