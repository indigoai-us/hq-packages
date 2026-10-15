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
#
# The session company comes from `hq core hq-session get company_slug`. A file
# inside another company's folder is refused. Exit codes: 0 ok, 1 the file has
# problems or the request was refused, 2 usage or setup error.
set -uo pipefail

self="${BASH_SOURCE[0]}"
while [ -L "$self" ]; do
  link="$(readlink "$self")"
  case "$link" in /*) self="$link" ;; *) self="$(dirname "$self")/$link" ;; esac
done
PACK_DIR="$(cd "$(dirname "$self")/.." && pwd)"
TEMPLATE="$PACK_DIR/template"
CLI="$TEMPLATE/shared/cli.ts"
MIN_NODE="22.6.0"

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

# Resolve the config file into RESOLVED and refuse one that belongs to another
# company. Runs in the current shell so a refusal prints its JSON and exits.
RESOLVED=""
resolve_file() { # [file]
  local root co file real other
  root="$(hq_root)" || fail 2 no-hq-root "Run this inside an HQ folder (one with companies/manifest.yaml), or set HQ_ROOT."
  co="$(session_company)" || fail 1 no-company "This session has no company. Bind one first: hq core hq-session set company_slug <slug>."
  case "$co" in *[!a-z0-9-]*|'') fail 1 bad-company "The session company \"$co\" is not a valid company slug." ;; esac
  if [ -n "${1:-}" ]; then
    file="$1"
  else
    file="$root/companies/$co/booking/booking.yaml"
  fi
  [ -f "$file" ] || fail 1 no-config "No booking settings at $file yet." "Ask HQ to set up booking for $co, or copy an example from knowledge/booking/examples/"
  real="$(real_path "$file")"
  case "$real" in
    "$root/companies/"*)
      other="${real#"$root/companies/"}"
      other="${other%%/*}"
      [ "$other" = "$co" ] || fail 1 other-company "That file belongs to another company. This session is bound to $co."
      ;;
  esac
  RESOLVED="$real"
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
    root="$(hq_root)" || fail 2 no-hq-root "Run this inside an HQ folder (one with companies/manifest.yaml), or set HQ_ROOT."
    co="$(session_company)" || fail 1 no-company "This session has no company. Bind one first: hq core hq-session set company_slug <slug>."
    f="$root/companies/$co/booking/booking.yaml"
    exists=false; [ -f "$f" ] && exists=true
    printf '{"ok":true,"company":"%s","file":"%s","exists":%s}\n' "$co" "$(json_escape "$f")" "$exists"
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
  ""|-h|--help|help)
    sed -n '2,15p' "$self" | sed 's/^# \{0,1\}//'
    [ -n "$cmd" ] || exit 2
    ;;
  *)
    fail 2 usage "Unknown command \"$cmd\". Use doctor, path, validate or slots."
    ;;
esac
