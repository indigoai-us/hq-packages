#!/usr/bin/env bash
# hq-booking — HQ Booking launcher for /booking.
#
# Subcommands (each prints one JSON object on stdout):
#   doctor                      check Node.js and the template's dependency
#   path                        print the session company's booking.yaml path and whether it exists
#   validate [file]             check booking.yaml (default: the session company's file)
#   slots [file] --event <id> [--duration <min>] [--from <ISO>] [--days <n>] [--now <ISO>]
#                [--busy <busy.json>] [--bookings <bookings.json>] [--tz <zone>]
#                               preview the times an event type would offer
#   setup [--from <example>] [--company-name <name>] [--rotate-owner-key]
#                               create booking.yaml and the owner key (key in the vault, hash in the file)
#   build                       validate, assemble and stage the app under workspace/booking-builds/{co}/
#   deploy [--access password|company|public] [--password <pw>] [--accept-database-billing]
#                               deploy the staged build to hq-deploy as an app with a database
#   dev [--port <n>]            run the app locally (sandbox, in memory) with the vault's owner key
#   owner <command> [--url <base>] ...
#                               owner API: bookings, booking, cancel, reschedule, no-show, link, links,
#                               times, analytics, outbox, notifications, approvals, approve, decline,
#                               agents, agent-key, revoke-agent, delegation, webhooks, webhook-deliveries,
#                               audit, delete-invitee, jobs-run, session
#   agent <command> <company>[/<event>] [--key-secret <NAME>] [--url <base>] ...
#                               book with another company's app as an HQ agent: event-types, times,
#                               book, bookings, cancel, reschedule
#   hosts list | add --email <e> [--name --id --timezone --hours --days --event-types] | remove <id>
#                               team hosts in booking.yaml
#
# The session company comes from `hq core hq-session get company_slug`. A file
# inside another company's folder is refused, and so is --company naming a
# different company. Exit codes: 0 ok, 1 the file has problems or the request
# was refused, 2 usage or setup error.
set -uo pipefail

self="${BASH_SOURCE[0]}"
while [ -L "$self" ]; do
  link="$(readlink "$self")"
  case "$link" in /*) self="$link" ;; *) self="$(dirname "$self")/$link" ;; esac
done
PACK_DIR="$(cd "$(dirname "$self")/.." && pwd)"
TEMPLATE="$PACK_DIR/template"
CLI="$TEMPLATE/shared/cli.ts"
LAUNCHER="$TEMPLATE/dev/launcher.ts"
EXAMPLES="$PACK_DIR/knowledge/booking/examples"
MIN_NODE="22.6.0"
OWNER_SECRET="BOOKING_OWNER_KEY"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

fail() { # code error message [fix]
  local fix=""
  [ -n "${4:-}" ] && fix=",\"fix\":\"$(json_escape "$4")\""
  printf '{"ok":false,"error":"%s","message":"%s"%s}\n' "$2" "$(json_escape "$3")" "$fix"
  exit "$1"
}

hq_root() {
  if [ -n "${HQ_ROOT:-}" ] && [ -f "$HQ_ROOT/companies/manifest.yaml" ]; then
    (cd "$HQ_ROOT" && pwd -P)
    return 0
  fi
  local d
  d="$(pwd -P)"
  while [ "$d" != "/" ]; do
    [ -f "$d/companies/manifest.yaml" ] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

session_company() {
  local co
  co="$(hq core hq-session get company_slug 2>/dev/null)" || return 1
  co="$(printf '%s' "$co" | tr -d '[:space:]')"
  [ -n "$co" ] || return 1
  printf '%s' "$co"
}

version_ge() { # a >= b for dotted versions
  local a="$1" b="$2" i x y
  IFS=. read -r -a A <<<"$a"
  IFS=. read -r -a B <<<"$b"
  for i in 0 1 2; do
    x="${A[$i]:-0}"; y="${B[$i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    [ "${x:-0}" -gt "${y:-0}" ] && return 0
    [ "${x:-0}" -lt "${y:-0}" ] && return 1
  done
  return 0
}

node_version() {
  command -v node >/dev/null 2>&1 || return 1
  node -p 'process.versions.node' 2>/dev/null
}

need_node() {
  local v
  v="$(node_version)" || fail 2 node-missing "HQ Booking needs Node.js $MIN_NODE or newer, and Node.js is not installed." "Install Node.js 22 LTS or newer from https://nodejs.org"
  version_ge "$v" "$MIN_NODE" || fail 2 node-too-old "HQ Booking needs Node.js $MIN_NODE or newer; this machine has $v." "Install Node.js 22 LTS or newer from https://nodejs.org"
}

need_deps() {
  [ -f "$TEMPLATE/node_modules/yaml/package.json" ] && return 0
  command -v npm >/dev/null 2>&1 || fail 2 npm-missing "npm is needed once to install HQ Booking's YAML reader." "Install Node.js (it includes npm)"
  # npm 11 mis-reads the lockfile with --prefix, so install from inside the folder.
  if ! (cd "$TEMPLATE" && npm ci --omit=dev --no-audit --no-fund --loglevel=error) >/dev/null 2>&1; then
    fail 2 deps-install-failed "Could not install HQ Booking's YAML reader with npm. Check the network connection and try again."
  fi
}

run_cli() {
  node --experimental-strip-types --no-warnings "$CLI" "$@"
}

run_launcher() {
  node --experimental-strip-types --no-warnings "$LAUNCHER" "$@"
}

# Physical path of a file, following symlinks on the file and its folders, so
# a link cannot point the company check at one place and the reader at another.
real_path() {
  local f="$1" link n=0
  while [ -L "$f" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || fail 1 bad-path "Too many links while resolving $1."
    link="$(readlink "$f")"
    case "$link" in /*) f="$link" ;; *) f="$(dirname "$f")/$link" ;; esac
  done
  printf '%s/%s' "$(cd "$(dirname "$f")" && pwd -P)" "$(basename "$f")"
}

# Session context: ROOT and CO. Refuses no company and bad slugs.
ROOT=""
CO=""
ctx() {
  ROOT="$(hq_root)" || fail 2 no-hq-root "Run this inside an HQ folder (one with companies/manifest.yaml), or set HQ_ROOT."
  CO="$(session_company)" || fail 1 no-company "This session has no company. Bind one first: hq core hq-session set company_slug <slug>."
  case "$CO" in *[!a-z0-9-]*|'') fail 1 bad-company "The session company \"$CO\" is not a valid company slug." ;; esac
}

# Refuse a path (file or folder) that resolves into another company's folder.
# Sets OWNED to the physical path. Runs in the current shell so a refusal exits.
OWNED=""
check_owned() { # path
  local real other
  if [ -d "$1" ]; then real="$(cd "$1" && pwd -P)"; else real="$(real_path "$1")"; fi
  case "$real/" in
    "$ROOT/companies/"*)
      other="${real#"$ROOT/companies/"}"
      other="${other%%/*}"
      [ "$other" = "$CO" ] || fail 1 other-company "That belongs to another company. This session is bound to $CO."
      ;;
  esac
  OWNED="$real"
}

# The company's booking folder, refused when it is a link into another company.
BDIR=""
booking_dir() {
  [ -d "$ROOT/companies/$CO" ] || fail 1 no-company-folder "There is no companies/$CO folder in this HQ."
  BDIR="$ROOT/companies/$CO/booking"
  if [ -e "$BDIR" ] || [ -L "$BDIR" ]; then
    check_owned "$BDIR"
    [ "$OWNED" = "$(cd "$ROOT/companies/$CO" && pwd -P)/booking" ] || fail 1 other-company "companies/$CO/booking points somewhere else. This session is bound to $CO."
  fi
}

# Resolve the config file into RESOLVED and refuse one that belongs to another
# company. Runs in the current shell so a refusal prints its JSON and exits.
RESOLVED=""
resolve_file() { # [file]
  local file
  [ -n "$CO" ] || ctx
  if [ -n "${1:-}" ]; then
    file="$1"
  else
    booking_dir
    file="$BDIR/booking.yaml"
  fi
  [ -f "$file" ] || fail 1 no-config "No booking settings at $file yet." "Ask HQ to set up booking for $CO (hq-booking.sh setup), or copy an example from knowledge/booking/examples/"
  check_owned "$file"
  RESOLVED="$OWNED"
}

# Strip --company <slug> from the arguments into ARGS, refusing another company.
ARGS=()
take_args() {
  ARGS=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--company" ]; then
      [ $# -ge 2 ] || fail 2 usage "--company needs a slug."
      [ "$2" = "$CO" ] || fail 1 other-company "This session is bound to $CO; it cannot act for $2."
      shift 2
      continue
    fi
    ARGS+=("$1")
    shift
  done
}

flag_value() { # name args... -> value of --name, empty when absent
  local name="$1"
  shift
  while [ $# -gt 0 ]; do
    if [ "$1" = "--$name" ] && [ $# -ge 2 ]; then printf '%s' "$2"; return 0; fi
    shift
  done
  return 1
}

has_flag() { # name args...
  local name="$1"
  shift
  for a in "$@"; do [ "$a" = "--$name" ] && return 0; done
  return 1
}

# 0 present, 1 absent; anything else stops with a plain error.
secret_exists() { # name
  local rc=0
  hq secrets --company "$CO" exists "$1" --quiet >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) fail 2 vault-unavailable "Could not reach the HQ vault for $CO. Sign in with /hq-login and try again." ;;
  esac
}

# Run a launcher command with one vault secret in its environment. The value
# goes from the vault to the child process only; nothing here sees it.
with_secret() { # name launcher-args...
  local name="$1" out rc=0
  shift
  out="$(hq secrets exec --only "$name" --company "$CO" -- node --experimental-strip-types --no-warnings "$LAUNCHER" "$@")" || rc=$?
  [ -n "$out" ] || fail 2 vault-unavailable "Could not read $name from the $CO vault. Sign in with /hq-login and try again."
  printf '%s\n' "$out"
  exit "$rc"
}

need_owner_key() {
  secret_exists "$OWNER_SECRET" || fail 1 no-owner-key "There is no owner key for $CO yet." "Run hq-booking.sh setup"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  doctor)
    v="$(node_version)" || v=""
    deps=false
    [ -f "$TEMPLATE/node_modules/yaml/package.json" ] && deps=true
    if [ -z "$v" ]; then
      fail 2 node-missing "HQ Booking needs Node.js $MIN_NODE or newer, and Node.js is not installed." "Install Node.js 22 LTS or newer from https://nodejs.org"
    fi
    if ! version_ge "$v" "$MIN_NODE"; then
      fail 2 node-too-old "HQ Booking needs Node.js $MIN_NODE or newer; this machine has $v." "Install Node.js 22 LTS or newer from https://nodejs.org"
    fi
    printf '{"ok":true,"node":"%s","depsInstalled":%s,"pack":"%s"}\n' "$v" "$deps" "$(json_escape "$PACK_DIR")"
    ;;
  path)
    ctx
    f="$ROOT/companies/$CO/booking/booking.yaml"
    exists=false; [ -f "$f" ] && exists=true
    printf '{"ok":true,"company":"%s","file":"%s","exists":%s}\n' "$CO" "$(json_escape "$f")" "$exists"
    ;;
  validate)
    [ $# -le 1 ] || fail 2 usage "validate takes at most one file path."
    need_node
    resolve_file "${1:-}"
    need_deps
    run_cli validate "$RESOLVED"
    ;;
  slots)
    file_arg=""
    if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then file_arg="$1"; shift; fi
    need_node
    resolve_file "$file_arg"
    need_deps
    run_cli slots "$RESOLVED" "$@"
    ;;
  setup)
    ctx
    take_args "$@"
    set -- "${ARGS[@]+"${ARGS[@]}"}"
    need_node
    booking_dir
    from="solo-consultant"; name=""; rotate=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --from) [ $# -ge 2 ] || fail 2 usage "--from needs an example name or file."; from="$2"; shift 2 ;;
        --company-name) [ $# -ge 2 ] || fail 2 usage "--company-name needs a name."; name="$2"; shift 2 ;;
        --rotate-owner-key) rotate="--rotate"; shift ;;
        *) fail 2 usage "setup takes --from <example>, --company-name <name> and --rotate-owner-key." ;;
      esac
    done
    file="$BDIR/booking.yaml"
    example=""
    if [ ! -f "$file" ]; then
      [ ! -L "$file" ] || fail 1 other-company "companies/$CO/booking/booking.yaml is a link. This session is bound to $CO."
      case "$from" in
        */*|*.yaml|*.yml) example="$from" ;;
        *) example="$EXAMPLES/$from.yaml" ;;
      esac
      [ -f "$example" ] || fail 2 usage "There is no example \"$from\". Use one of: $(cd "$EXAMPLES" && ls *.yaml | sed 's/\.yaml$//' | paste -sd, -)."
      check_owned "$example"
      example="$OWNED"
      mkdir -p "$BDIR"
    else
      resolve_file "$file"
      file="$RESOLVED"
    fi
    need_deps
    set -- --file "$file" --company "$CO"
    [ -n "$example" ] && set -- "$@" --example "$example"
    [ -n "$name" ] && set -- "$@" --company-name "$name"
    if [ -z "$rotate" ] && secret_exists "$OWNER_SECRET"; then
      with_secret "$OWNER_SECRET" setup "$@" --key-in-env
    fi
    [ -n "$rotate" ] && set -- "$@" --rotate
    run_launcher setup "$@"
    ;;
  build)
    ctx
    take_args "$@"
    [ ${#ARGS[@]} -eq 0 ] || fail 2 usage "build takes no arguments."
    need_node
    resolve_file
    need_deps
    command -v npm >/dev/null 2>&1 || fail 2 npm-missing "npm is needed to build the booking app." "Install Node.js (it includes npm)"
    if ! check="$(run_cli validate "$RESOLVED")"; then printf '%s\n' "$check"; exit 1; fi
    out="$ROOT/workspace/booking-builds/$CO"
    app="$out/app"
    stage="$out/stage"
    rm -rf "$app" "$stage" "$out/build.json"
    mkdir -p "$app"
    if ! (cd "$TEMPLATE" && tar --exclude=./node_modules --exclude=./dist -cf - .) | (cd "$app" && tar -xf -); then
      fail 2 copy-failed "Could not copy the app template to $app."
    fi
    overrides=""
    if [ -e "$BDIR/overrides" ]; then
      [ -d "$BDIR/overrides" ] || fail 1 bad-overrides "companies/$CO/booking/overrides must be a folder."
      check_owned "$BDIR/overrides"
      overrides="$OWNED"
    fi
    if ! (cd "$app" && npm ci --no-audit --no-fund --loglevel=error) >"$out/npm.log" 2>&1; then
      fail 2 deps-install-failed "Could not install the app's packages with npm. See $out/npm.log."
    fi
    if ! (cd "$app" && node -e 'process.exit(require("./package.json").scripts?.build ? 0 : 1)'); then
      fail 2 no-ui-build "This version of the template has no booking pages to build (no build script)."
    fi
    if [ -n "$overrides" ]; then
      (cd "$app" && BOOKING_OVERRIDES_DIR="$overrides" BOOKING_CONFIG="$RESOLVED" npm run build) >"$out/build.log" 2>&1
    else
      (cd "$app" && env -u BOOKING_OVERRIDES_DIR BOOKING_CONFIG="$RESOLVED" npm run build) >"$out/build.log" 2>&1
    fi || fail 1 build-failed "The booking pages did not build. The last lines of $out/build.log say: $(tail -5 "$out/build.log" | tr '\n' ' ')"
    staged="$(cd "$app" && node --experimental-strip-types --no-warnings dev/stage.ts "$RESOLVED" "$stage" --dist "$app/dist")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      case "$staged" in
        *"hq-deploy accepts at most"*) printf '{"ok":false,"error":"too-many-files","message":"The app has more files than hq-deploy accepts (100). Remove extra files from the overrides or public folder.","stage":%s}\n' "${staged:-null}" ;;
        *) printf '{"ok":false,"error":"stage-failed","message":"The app could not be staged for hq-deploy.","stage":%s}\n' "${staged:-null}" ;;
      esac
      exit 1
    fi
    OUT_JSON="$staged" CONFIG_FILE="$RESOLVED" META="$out/build.json" CO="$CO" APP="$app" OV="$overrides" node -e '
      const fs = require("fs"), crypto = require("crypto");
      const s = JSON.parse(process.env.OUT_JSON);
      const sha = crypto.createHash("sha256").update(fs.readFileSync(process.env.CONFIG_FILE)).digest("hex");
      const meta = { company: process.env.CO, configSha256: sha, builtAt: new Date().toISOString(), stageDir: s.out, files: s.files, overrides: process.env.OV || null };
      fs.writeFileSync(process.env.META, JSON.stringify(meta, null, 2) + "\n");
      console.log(JSON.stringify({ ok: true, company: meta.company, buildDir: process.env.APP, stageDir: s.out, files: s.files, maxFiles: 100, overrides: meta.overrides, next: "Deploy it: hq-booking.sh deploy" }));
    '
    ;;
  deploy)
    ctx
    take_args "$@"
    need_node
    resolve_file
    need_deps
    booking_dir
    out="$ROOT/workspace/booking-builds/$CO"
    run_launcher deploy --company "$CO" --root "$ROOT" --file "$RESOLVED" --stage "$out/stage" \
      --build-meta "$out/build.json" --deploy-json "$BDIR/deploy.json" \
      --scripts "$ROOT/.claude/skills/deploy/scripts" "${ARGS[@]+"${ARGS[@]}"}"
    ;;
  dev)
    ctx
    take_args "$@"
    need_node
    resolve_file
    need_deps
    port="$(flag_value port "${ARGS[@]+"${ARGS[@]}"}")" || port=5180
    need_owner_key
    # Long-running: prints one JSON line when listening, then serves until stopped.
    exec hq secrets exec --only "$OWNER_SECRET" --company "$CO" -- node --experimental-strip-types --no-warnings "$LAUNCHER" dev-serve --config "$RESOLVED" --port "$port"
    ;;
  owner)
    ctx
    take_args "$@"
    [ ${#ARGS[@]} -gt 0 ] || fail 2 usage "owner needs a command, such as owner bookings."
    need_node
    need_deps
    booking_dir
    need_owner_key
    with_secret "$OWNER_SECRET" owner "${ARGS[@]}" --deploy-json "$BDIR/deploy.json"
    ;;
  agent)
    ctx
    take_args "$@"
    set -- "${ARGS[@]+"${ARGS[@]}"}"
    [ $# -ge 2 ] || fail 2 usage "Use: agent <times|book|event-types|bookings|cancel|reschedule> <company>[/<event>] ..."
    sub="$1"; target="$2"; shift 2
    tco="${target%%/*}"
    event=""; [ "$tco" != "$target" ] && event="${target#*/}"
    case "$tco" in *[!a-z0-9-]*|'') fail 2 usage "\"$tco\" is not a company slug." ;; esac
    case "$event" in *[!a-z0-9-]*) fail 2 usage "\"$event\" is not an event type id." ;; esac
    need_node
    need_deps
    secret="$(flag_value key-secret "$@")" || secret="BOOKING_AGENT_KEY_$(printf '%s' "$tco" | tr 'a-z-' 'A-Z_')"
    [[ "$secret" =~ ^[A-Z][A-Z0-9_]*$ ]] || fail 2 usage "--key-secret must be a vault secret name such as BOOKING_AGENT_KEY_ACME."
    url="$(flag_value url "$@")" || url=""
    if [ -z "$url" ]; then
      booking_dir
      if [ "$tco" = "$CO" ] && [ -f "$BDIR/deploy.json" ]; then
        url="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).url || "")' "$BDIR/deploy.json")"
      fi
      [ -n "$url" ] || url="https://booking-$tco.${HQ_DEPLOY_DOMAIN:-indigo-hq.com}"
    fi
    rest=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --key-secret|--url) shift 2 ;;
        *) rest+=("$1"); shift ;;
      esac
    done
    secret_exists "$secret" || fail 1 no-agent-key "There is no agent key named $secret in the $CO vault." "Ask $tco's owner for an agent key, then store it with hq secrets set $secret"
    set -- agent "$sub"
    case "$sub" in cancel|reschedule) [ ${#rest[@]} -gt 0 ] && { set -- "$@" "${rest[0]}"; rest=("${rest[@]:1}"); } ;; esac
    [ -n "$event" ] && set -- "$@" --event "$event"
    with_secret "$secret" "$@" --base "$url" --key-env "$secret" "${rest[@]+"${rest[@]}"}"
    ;;
  hosts)
    ctx
    take_args "$@"
    [ ${#ARGS[@]} -gt 0 ] || fail 2 usage "Use hosts list, hosts add --email <email>, or hosts remove <id>."
    need_node
    resolve_file
    need_deps
    run_launcher hosts "${ARGS[@]}" --file "$RESOLVED" --company "$CO"
    ;;
  ""|-h|--help|help)
    sed -n '2,33p' "$self" | sed 's/^# \{0,1\}//'
    [ -n "$cmd" ] || exit 2
    ;;
  *)
    fail 2 usage "Unknown command \"$cmd\". Use doctor, path, validate, slots, setup, build, deploy, dev, owner, agent or hosts."
    ;;
esac
