#!/usr/bin/env bash
# e2e-smoke.sh — the whole-pack offline smoke (US-007).
#
#   e2e-smoke.sh [--keep] [--seed-fault <name>] [--list-faults]
#
# Runs the entire arc on throwaway fixtures under $TMPDIR:
#
#   install  -> scan-packages.sh wires the pack into a fixture HQ root
#   onboard  -> onboard-firm.sh writes + validates companies/{firm}/client-service.yaml
#   client   -> new-client.sh engagement (firm-bound) + client-home (client-bound)
#   pack     -> client-pack.sh scaffold / apply / fork / update / remove
#
# File state AND manifest contents are asserted at every step: the wired
# symlinks, the firm config's slot tri-state, companies/manifest.yaml, the
# staged bundle's pack.json, and .hq-packs/{pack}/.hq-pack-manifest.json
# (sourceFirm, packName, version, per-file sha256, grantedVia, fork markers).
#
# OFFLINE IS PROVEN, NOT ASSERTED
#   Every command runs with PATH prefixed by a shim dir in which curl, wget,
#   gh, aws, ssh, scp, nc and open are recording stubs that log and exit 97. The
#   log must be empty at every checkpoint. "No cloud or vendor call was made" is
#   therefore a mechanical result, not a claim about the source.
#
#   `hq` is shimmed SELECTIVELY, because `hq` is no longer one thing.
#   core/scripts/scan-packages.sh is now a FORWARDER — its implementation moved
#   into the hq CLI and it exec's `hq core --hq-root <root> scan-packages`. That
#   subcommand is a purely LOCAL host operation: it symlinks a pack's
#   contributions into an HQ root and touches nothing off-machine. Shimming `hq`
#   wholesale was correct while scan-packages.sh was self-contained bash; against
#   a forwarder it only kills the install step and proves nothing.
#
#   So the hq shim discriminates on the subcommand:
#     `hq core ...`  -> delegated to the resolved real CLI, recorded in a
#                       separate LOCAL log; never a violation.
#     everything else (secrets, sync, dm, invite, publish, deploy, files, login,
#                       whoami, run, packages, ...) -> logged to the shim log and
#                       exit 97. Those are what the offline proof exists to catch.
#   Step 1 asserts BOTH directions at once: the local call demonstrably happened,
#   and it demonstrably was not written to the violation log.
#
# THE HARNESS MUST BE ABLE TO FAIL
#   Nothing here prints success unconditionally. Every assertion increments a
#   counter, and the exit status is derived from that counter alone. `--seed-fault`
#   patches the INSTALLED (fixture) copy of client-pack.sh — never the real pack
#   file — so the smoke can be shown to go red on a real regression:
#
#     bash e2e-smoke.sh                          # -> exit 0
#     bash e2e-smoke.sh --seed-fault fork-detect # -> exit 1, names what failed
#
#   The run also checksums the real pack tree before and after and fails if a
#   single byte moved.
#
# Cleanup runs from a trap, so the fixture tree is removed on success, on
# failure, and on an interrupt.
#
# Exit codes
#   0  every assertion passed
#   1  at least one assertion failed
#   2  environment / usage problem
#
# Policy notes
#   hq-bash-set-e-status-returns          — status-returning functions are called
#                                           in an `if` or with `|| rc=$?`, never bare.
#   hq-auto-select-skips-underscore-pseudo-dirs
#                                         — asserted live: a `_`-prefixed dir is
#                                           planted under .hq-packs/ and under the
#                                           firm pack, and must never be selected.
#   hq-regression-test-must-fail-with-fix-reverted
#                                         — that is what --seed-fault exists for.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PACK="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
HOST_ROOT="$(cd -- "${PACK}/../../.." && pwd -P)"

KEEP=0
SEED_FAULT=""

FAULTS='fork-detect|classify() always answers "clean" — fork detection is dead
manifest-sha|the bundle sha is recorded as zeroes — the manifest stops describing the bytes
remove-deletes-forks|remove deletes forked files instead of keeping them'

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)        KEEP=1; shift ;;
    --seed-fault)  SEED_FAULT="${2:-}"; shift 2 ;;
    --list-faults) printf '%s\n' "$FAULTS" | sed 's/|/  —  /' ; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    *)             printf 'ERROR  E_USAGE  unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for tool in jq yq shasum python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'ERROR  E_ENV_%s_MISSING  %s is required\n' "$(printf '%s' "$tool" | tr 'a-z' 'A-Z')" "$tool" >&2
    exit 2
  }
done

SCAN="${HOST_ROOT}/core/scripts/scan-packages.sh"
[ -f "$SCAN" ] || {
  printf 'ERROR  E_ENV_SCAN_PACKAGES_MISSING  no %s — the install step cannot run\n' "$SCAN" >&2
  exit 2
}

if [ -n "$SEED_FAULT" ]; then
  case "$SEED_FAULT" in
    fork-detect|manifest-sha|remove-deletes-forks) ;;
    *) printf 'ERROR  E_USAGE  unknown fault: %s (see --list-faults)\n' "$SEED_FAULT" >&2; exit 2 ;;
  esac
fi

# ---------------------------------------------------------------------------
# fixture root + cleanup trap (fires on success, failure and interrupt)
# ---------------------------------------------------------------------------

WORK="$(mktemp -d -t client-service-e2e)"
CLEANED=0
cleanup() {
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  if [ "$KEEP" -eq 1 ]; then
    printf '\ncleanup: fixtures KEPT at %s (--keep)\n' "$WORK"
    return 0
  fi
  rm -rf "$WORK"
  if [ -d "$WORK" ]; then
    printf '\ncleanup: FAILED to remove %s\n' "$WORK" >&2
  else
    printf '\ncleanup: removed all fixture dirs under %s\n' "$WORK"
  fi
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

HQ="${WORK}/hq"
IPACK="${HQ}/core/packages/hq-pack-client-service"
SHIMS="${WORK}/shims"
EXTLOG="${WORK}/external-calls.log"
LOCALLOG="${WORK}/local-hq-calls.log"
NO_SECRETS="${WORK}/no-secret-names"

mkdir -p "$SHIMS"
: > "$EXTLOG"
: > "$LOCALLOG"
: > "$NO_SECRETS"

# Total shims: nothing in this pack has any business invoking these at all.
for cmd in curl wget gh aws ssh scp nc open; do
  cat > "${SHIMS}/${cmd}" <<SHIM
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "${EXTLOG}"
exit 97
SHIM
  chmod +x "${SHIMS}/${cmd}"
done

# ---------------------------------------------------------------------------
# the selective `hq` shim
#
# Resolve ONE real CLI up front, from the pristine PATH, before the shim dir is
# ever prepended — and bake its absolute argv into the shim so the delegation
# can never re-enter the shim by name.
#
# The probe is for the CAPABILITY the forwarder needs, not for liveness, because
# two weaker probes both give a wrong answer here:
#   * "is it on PATH" — a dangling npm symlink is `command -v`-visible and
#     completely broken.
#   * "does it answer --version" — an older CLI answers happily and then dies on
#     `core` with `unknown command`, which would fail the install step for a
#     reason that has nothing to do with this pack.
# So the probe reads `core --help` and requires `scan-packages` to be listed.
# It must stay a HELP read: `core scan-packages --help` is not a help path, it
# actually wires packs into whatever root it is pointed at.
# ---------------------------------------------------------------------------

hq_cli_works() {  # status-returning: only ever called in `if`
  "$@" core --help 2>/dev/null | grep -q 'scan-packages'
}

HQ_REAL_ARGV=""     # shell-quoted argv prefix, baked into the shim
HQ_REAL_WHY=""
HQ_ON_PATH="$(command -v hq 2>/dev/null || true)"
# Overridable so a host with neither a working global nor this checkout can point
# the harness at its own build.
HQ_REPO_CLI="${HQ_SMOKE_CLI:-${HOST_ROOT}/repos/private/hq-cli/dist/index.js}"
NODE_BIN="$(command -v node 2>/dev/null || true)"

if [ -n "$HQ_ON_PATH" ] && hq_cli_works "$HQ_ON_PATH"; then
  HQ_REAL_ARGV="$(printf '%q' "$HQ_ON_PATH")"
  HQ_REAL_WHY="$HQ_ON_PATH (v$("$HQ_ON_PATH" --version 2>/dev/null | head -1))"
elif [ -n "$NODE_BIN" ] && [ -f "$HQ_REPO_CLI" ] && hq_cli_works "$NODE_BIN" "$HQ_REPO_CLI"; then
  HQ_REAL_ARGV="$(printf '%q %q' "$NODE_BIN" "$HQ_REPO_CLI")"
  HQ_REAL_WHY="node ${HQ_REPO_CLI} (v$("$NODE_BIN" "$HQ_REPO_CLI" --version 2>/dev/null | head -1)) — hq on PATH is absent or not runnable"
else
  printf 'ERROR  E_ENV_HQ_CLI_MISSING  no hq CLI that provides `hq core scan-packages`\n' >&2
  printf '  core/scripts/scan-packages.sh is a forwarder into that subcommand, so the\n' >&2
  printf '  install step cannot run without one. Neither candidate listed it under\n' >&2
  printf '  `core --help`:\n' >&2
  printf '    hq on PATH        : %s\n' "${HQ_ON_PATH:-<not found>}" >&2
  printf '    node + local build: %s\n' "$HQ_REPO_CLI" >&2
  printf '  Install or upgrade it (npm install -g @indigoai-us/hq-cli) or point the\n' >&2
  printf '  harness at a build that has it with HQ_SMOKE_CLI=<path to dist/index.js>.\n' >&2
  printf '  Failing loudly rather than silently skipping the install step.\n' >&2
  exit 2
fi

{
  printf '#!/usr/bin/env bash\n'
  printf '# SELECTIVE hq shim, generated by e2e-smoke.sh.\n'
  printf '#   `hq core ...` is a local host operation (scan-packages symlinking into an\n'
  printf '#   HQ root) -> delegated to the real CLI, recorded as local, NOT a violation.\n'
  printf '#   every other subcommand can reach the network -> logged and exit 97.\n'
  printf 'if [ "${1:-}" = "core" ]; then\n'
  printf '  if [ "${HQ_SMOKE_SHIM_DEPTH:-0}" -ge 3 ]; then\n'
  printf '    printf %s "$*" >> %q\n' "'hq %s  [BLOCKED: delegation recursed]\\n'" "$EXTLOG"
  printf '    exit 97\n'
  printf '  fi\n'
  printf '  HQ_SMOKE_SHIM_DEPTH=$(( ${HQ_SMOKE_SHIM_DEPTH:-0} + 1 )); export HQ_SMOKE_SHIM_DEPTH\n'
  printf '  printf %s "$*" >> %q\n' "'hq %s\\n'" "$LOCALLOG"
  printf '  exec %s "$@"\n' "$HQ_REAL_ARGV"
  printf 'fi\n'
  printf 'printf %s "$(basename "$0")" "$*" >> %q\n' "'%s %s\\n'" "$EXTLOG"
  printf 'exit 97\n'
} > "${SHIMS}/hq"
chmod +x "${SHIMS}/hq"
bash -n "${SHIMS}/hq" 2>/dev/null || {
  printf 'ERROR  E_ENV_SHIM_UNPARSEABLE  the generated hq shim does not parse\n' >&2
  exit 2
}

# ---------------------------------------------------------------------------
# counters — the exit status is derived from these and nothing else
# ---------------------------------------------------------------------------

FAILS=0
PASSES=0
STEP=""

hdr()  { STEP="$1"; printf '\n=== %s\n' "$1"; }
ok()   { PASSES=$((PASSES + 1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAILS=$((FAILS + 1)); printf '  FAIL  [%s] %s\n' "$STEP" "$*"; }
note() { printf '  ....  %s\n' "$*"; }
show() { printf '%s\n' "$1" | sed 's/^/        /'; }

assert_eq()     { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
assert_ne()     { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (unexpectedly equal to '$2')"; fi; }
assert_exists() { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
assert_absent() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (still present: $2)"; fi; }
assert_link()   { if [ -L "$2" ]; then ok "$1"; else bad "$1 (not a symlink: $2)"; fi; }
assert_has()    { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)" ;; esac; }
assert_lacks()  { case "$2" in *"$3"*) bad "$1 (found '$3' in output)" ;; *) ok "$1" ;; esac; }

assert_offline() { # assert_offline <label>
  if [ -s "$EXTLOG" ]; then
    bad "$1 — external call(s) attempted: $(tr '\n' '; ' < "$EXTLOG")"
    : > "$EXTLOG"
  else
    ok "$1 (shim log empty: curl/wget/gh/aws/ssh/scp/nc/open and every networked hq subcommand never invoked)"
  fi
}

OUT=""
RC=0
run() { # run <script> <args...> — never called bare under a status contract
  RC=0
  OUT="$(PATH="${SHIMS}:${PATH}" bash "$@" 2>&1)" || RC=$?
  return 0
}

sha_of()  { shasum -a 256 -- "$1" 2>/dev/null | awk '{print $1}'; }

# jq's `//` collapses a legitimate `false` into the default, so manifest booleans
# are read through an explicit presence test instead. An entry that is not there
# at all answers "absent", which is never the same answer as false.
man_field() { # man_field <manifest> <path> <field> -> value | "absent"
  jq -r --arg p "$2" --arg f "$3" \
    '[.files[]? | select(type == "object" and .path == $p)
      | (if has($f) then (.[$f] | tostring) else "absent" end)]
     | if length == 0 then "absent" else .[0] end' "$1" 2>/dev/null || printf 'absent'
}
man_sha_is() { # man_sha_is <manifest> <path> <sha> -> true | false | "absent"
  jq -r --arg p "$2" --arg s "$3" \
    '[.files[]? | select(type == "object" and .path == $p)
      | (((.sha256 // "") == $s) | tostring)]
     | if length == 0 then "absent" else .[0] end' "$1" 2>/dev/null || printf 'absent'
}
tree_sha() { # tree_sha <dir> -> a stable manifest of every file in the tree
  ( cd "$1" 2>/dev/null && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# fixture identity — every name here is invented
# ---------------------------------------------------------------------------

FIRM="northwind-fixture"
CLIENT="atlas-fixture"
PACKNAME="house-kit"
MAN_REL=".hq-packs/${PACKNAME}/.hq-pack-manifest.json"

printf 'client-service e2e-smoke\n'
printf '  pack under test : %s\n' "$PACK"
printf '  fixture root    : %s\n' "$WORK"
printf '  firm=%s client=%s pack=%s (invented; no real company tree is touched)\n' \
  "$FIRM" "$CLIENT" "$PACKNAME"
printf '  hq CLI (local ops): %s\n' "$HQ_REAL_WHY"
printf '                      only `hq core ...` reaches it; every other subcommand is blocked at 97\n'
[ -n "$SEED_FAULT" ] && printf '  SEEDED FAULT    : %s (patched into the FIXTURE copy only)\n' "$SEED_FAULT"

REAL_PACK_BEFORE="$(tree_sha "$PACK")"

# ===========================================================================
hdr "1  INSTALL — the pack is wired into a fresh HQ root"
# ===========================================================================

mkdir -p "${HQ}/core/packages" "${HQ}/core/scripts" "${HQ}/core/policies" \
         "${HQ}/core/workers/public" "${HQ}/core/knowledge/public" \
         "${HQ}/.claude/skills" "${HQ}/companies" "${HQ}/workspace"
cp -R "$PACK" "${HQ}/core/packages/hq-pack-client-service"
cp "$SCAN" "${HQ}/core/scripts/scan-packages.sh"

# The fixture copy is what gets faulted; the real pack file is never opened for
# writing by this script at all.
seed_fault_into_fixture() { # seed_fault_into_fixture <name> -> 0 ok, 1 could not
  local name="$1" target="${IPACK}/scripts/client-pack.sh" old new rc=0
  case "$name" in
    fork-detect)
      old='  if [ "$cur" = "$msha" ]; then printf '"'"'clean'"'"'; else printf '"'"'fork'"'"'; fi'
      new='  printf '"'"'clean'"'"'  # SEEDED FAULT: fork detection removed'
      ;;
    manifest-sha)
      old='    bsha="$(sha_of "${BUNDLE}/content/${rel}")"'
      new='    bsha="0000000000000000000000000000000000000000000000000000000000000000"  # SEEDED FAULT'
      ;;
    remove-deletes-forks)
      old='        printf '"'"'%s\n'"'"' "$(printf '"'"'%s'"'"' "$entry" | jq -c '"'"'. + {forked:true, retainedOnRemove:true}'"'"')" >> "$retained"'
      new='        rm -f -- "${CLIENT_DIR}/${rel}"  # SEEDED FAULT: forks are deleted'
      ;;
    *) return 1 ;;
  esac
  FAULT_OLD="$old" FAULT_NEW="$new" python3 - "$target" <<'PY' || rc=$?
import os, sys
path = sys.argv[1]
src = open(path).read()
old, new = os.environ["FAULT_OLD"], os.environ["FAULT_NEW"]
n = src.count(old)
if n != 1:
    sys.stderr.write("seed anchor matched %d times, expected exactly 1\n" % n)
    sys.exit(3)
open(path, "w").write(src.replace(old, new))
PY
  [ "$rc" -eq 0 ] || return 1
  # A syntax-broken copy would fail for the wrong reason, which would make the
  # demonstration worthless.
  bash -n "$target" >/dev/null 2>&1 || return 1
  return 0
}

if [ -n "$SEED_FAULT" ]; then
  src_rc=0
  seed_fault_into_fixture "$SEED_FAULT" || src_rc=$?
  if [ "$src_rc" -eq 0 ]; then
    note "seeded fault '${SEED_FAULT}' into ${IPACK}/scripts/client-pack.sh (a copy)"
    assert_ne "the faulted fixture copy differs from the real client-pack.sh" \
      "$(sha_of "${PACK}/scripts/client-pack.sh")" "$(sha_of "${IPACK}/scripts/client-pack.sh")"
  else
    bad "could not seed fault '${SEED_FAULT}' — the demonstration is inconclusive"
  fi
fi

# scan-packages.sh takes the HQ root from the environment, not a flag.
RC=0
OUT="$(cd "$HQ" && HQ_ROOT="$HQ" PATH="${SHIMS}:${PATH}" bash core/scripts/scan-packages.sh 2>&1)" || RC=$?
show "$OUT"
assert_eq "scan-packages.sh exits 0" "0" "$RC"

assert_link "skill /onboard-firm is wired"    "${HQ}/.claude/skills/onboard-firm"
assert_link "skill /new-client is wired"      "${HQ}/.claude/skills/new-client"
assert_link "skill /client-pack is wired"     "${HQ}/.claude/skills/client-pack"
assert_link "skill /handover-client is wired" "${HQ}/.claude/skills/handover-client"
assert_exists "  ... and resolves to the pack payload" "${HQ}/.claude/skills/client-pack/SKILL.md"
assert_link "worker client-services is wired" "${HQ}/core/workers/public/client-services"
assert_exists "  ... with its worker.yaml"     "${HQ}/core/workers/public/client-services/worker.yaml"
assert_link "knowledge client-service is wired" "${HQ}/core/knowledge/public/client-service"
assert_exists "  ... with the frozen schema" \
  "${HQ}/core/knowledge/public/client-service/client-service.schema.yaml"

POLICY_N=0
for p in client-service-engagement-is-source-of-truth client-service-internal-external-split \
         client-service-approval-gate-external-actions client-service-billing-signed-and-test-first \
         client-service-materialize-not-mount; do
  [ -L "${HQ}/core/policies/${p}.md" ] && POLICY_N=$((POLICY_N + 1))
done
assert_eq "all 5 declared policies are wired into core/policies/" "5" "$POLICY_N"

# Every script the arc is about to drive must at least parse after install.
PARSE_BAD=""
for s in onboard-firm.sh new-client.sh client-pack.sh validate-config.sh detect-tools.sh; do
  bash -n "${IPACK}/scripts/${s}" >/dev/null 2>&1 || PARSE_BAD="${PARSE_BAD} ${s}"
done
assert_eq "every installed script parses" "" "$PARSE_BAD"

# The install now runs THROUGH the hq CLI, so prove the shim discriminated in both
# directions at the same checkpoint. Order matters: assert_offline truncates EXTLOG.
assert_has "the install really reached the hq CLI (scan-packages.sh is a forwarder now)" \
  "$(cat "$LOCALLOG" 2>/dev/null)" "core"
assert_has "  ... specifically the scan-packages subcommand" \
  "$(cat "$LOCALLOG" 2>/dev/null)" "scan-packages"
assert_lacks "  ... and the allowed local call was NOT recorded as a violation" \
  "$(cat "$EXTLOG" 2>/dev/null)" "hq core"

assert_offline "install made no external call"

ONBOARD="${IPACK}/scripts/onboard-firm.sh"
NEWCLIENT="${IPACK}/scripts/new-client.sh"
CLIENTPACK="${IPACK}/scripts/client-pack.sh"
VALIDATE="${IPACK}/scripts/validate-config.sh"
SLOTSTATE="${IPACK}/workers/client-services/scripts/slot-state.sh"

# ===========================================================================
hdr "2  ONBOARD-FIRM — fixture answers, no prompts"
# ===========================================================================

mkdir -p "${HQ}/companies/${FIRM}/settings"
printf 'slug: %s\nname: Northwind Fixture Partners\ncloud: false\n' "$FIRM" \
  > "${HQ}/companies/${FIRM}/company.yaml"
{
  printf 'companies:\n'
  printf '  %s:\n    name: Northwind Fixture Partners\n    path: companies/%s\n' "$FIRM" "$FIRM"
} > "${HQ}/companies/manifest.yaml"

# crm BOUND, portal/billing/agreements EMPTY, transcripts deliberately UNDECLARED.
run "$ONBOARD" --company "$FIRM" --root "$HQ" --no-auto \
  --secret-names-file "$NO_SECRETS" \
  --bind crm=fixture-crm:mcp --empty portal --empty billing --empty agreements \
  --skip transcripts
show "$OUT"
assert_eq "onboard-firm exits 0" "0" "$RC"

CFG="${HQ}/companies/${FIRM}/client-service.yaml"
assert_exists "companies/{firm}/client-service.yaml was written" "$CFG"
assert_exists "clients/ was scaffolded" "${HQ}/companies/${FIRM}/clients"
assert_exists "the engagement template was scaffolded" \
  "${HQ}/companies/${FIRM}/clients/_templates/engagement.template.md"

run "$VALIDATE" --quiet "$CFG"
assert_eq "the written config validates against the frozen schema" "0" "$RC"

slot_state() { # slot_state <slot>
  PATH="${SHIMS}:${PATH}" bash "$SLOTSTATE" --config "$CFG" --slot "$1" --format kv 2>/dev/null \
    | sed -n 's/.*state=\([a-z]*\).*/\1/p' | head -1
}
assert_eq "config contents — crm is BOUND"          "bound"      "$(slot_state crm)"
assert_eq "config contents — portal is EMPTY"       "empty"      "$(slot_state portal)"
assert_eq "config contents — transcripts is UNDECLARED (not downgraded to empty)" \
  "undeclared" "$(slot_state transcripts)"
assert_eq "config contents — the bound tool is recorded verbatim" "fixture-crm" \
  "$(yq -r '.slots.crm.binding.tool_name // ""' "$CFG")"
assert_eq "config contents — with its connector" "mcp" \
  "$(yq -r '.slots.crm.binding.connector // ""' "$CFG")"
assert_eq "config contents — EMPTY is written positively as binding: null" "null" \
  "$(yq -r '.slots.portal.binding' "$CFG")"
assert_eq "config contents — UNDECLARED is left ABSENT, not written as empty" "false" \
  "$(yq -r 'has("slots") and (.slots | has("transcripts"))' "$CFG")"

CFG_SHA="$(sha_of "$CFG")"
run "$ONBOARD" --company "$FIRM" --root "$HQ" --no-auto \
  --secret-names-file "$NO_SECRETS" \
  --bind crm=fixture-crm:mcp --empty portal --empty billing --empty agreements \
  --skip transcripts
assert_eq "a second onboard run exits 0" "0" "$RC"
assert_eq "  ... and leaves client-service.yaml byte-identical" "$CFG_SHA" "$(sha_of "$CFG")"

assert_offline "onboarding made no external call"

# ===========================================================================
hdr "3  NEW-CLIENT — local-only, invites declined, two bound sessions"
# ===========================================================================

run "$NEWCLIENT" engagement --pack-dir "$IPACK" --hq-root "$HQ" \
  --session-company "$FIRM" --firm "$FIRM" --client "$CLIENT" \
  --client-name "Atlas Fixture Ltd" --local-only
show "$OUT"
assert_eq "phase 1 (FIRM-bound) exits 0" "0" "$RC"

run "$NEWCLIENT" client-home --pack-dir "$IPACK" --hq-root "$HQ" \
  --session-company "$CLIENT" --client "$CLIENT" --invites declined --local-only
show "$OUT"
assert_eq "phase 2 (CLIENT-bound) exits 0" "0" "$RC"
assert_has "  ... local-only is reported as a skip with a reason" "$OUT" "Local-only:"

ENG="${HQ}/companies/${FIRM}/clients/${CLIENT}/engagement.md"
CODIR="${HQ}/companies/${CLIENT}"
assert_exists "firm-side engagement.md exists"                "$ENG"
assert_exists "  ... with a pending adapter entry for the BOUND slot" \
  "${HQ}/companies/${FIRM}/clients/${CLIENT}/adapters/crm.md"
assert_absent "  ... and none for the EMPTY slot" \
  "${HQ}/companies/${FIRM}/clients/${CLIENT}/adapters/portal.md"
assert_exists "client-side company scaffold exists"           "${CODIR}/company.yaml"
assert_exists "  ... with a board.json"                       "${CODIR}/board.json"
assert_exists "  ... with the handover checklist staged"      "${CODIR}/handover-checklist.md"
assert_has    "the engagement rendered from the firm template" "$(cat "$ENG" 2>/dev/null)" \
  "Atlas Fixture Ltd"
assert_lacks  "no template placeholder survived rendering"     "$(cat "$ENG" 2>/dev/null)" "{{"

assert_eq "manifest contents — the client is registered in companies/manifest.yaml" \
  "Atlas Fixture Ltd" "$(yq -r '.companies["'"$CLIENT"'"].name // ""' "${HQ}/companies/manifest.yaml")"
assert_eq "manifest contents — the client is NOT marked cloud-backed" \
  "false" "$(yq -r '.cloud' "${CODIR}/company.yaml")"
assert_absent "no invite artifact was staged (the gate said no)" \
  "${HQ}/workspace/client-service/new-client/${CLIENT}-invites.txt"

assert_offline "client creation made no external call"

# ===========================================================================
hdr "4  CLIENT-PACK scaffold — firm-bound, stages a portable bundle"
# ===========================================================================

mkdir -p "${HQ}/companies/${FIRM}/skills/firm-brief"
printf 'the firm house brief\n' > "${HQ}/companies/${FIRM}/skills/firm-brief/SKILL.md"

run "$CLIENTPACK" scaffold --hq-root "$HQ" --session-company "$FIRM" \
  --firm "$FIRM" --pack "$PACKNAME" --include skills/firm-brief
show "$OUT"
assert_eq "scaffold exits 0" "0" "$RC"

PDIR="${HQ}/companies/${FIRM}/packs/${PACKNAME}"
BDIR="${HQ}/workspace/pack-staging/${FIRM}/${PACKNAME}"
assert_exists "packs/{pack}/pack.yaml created"                  "${PDIR}/pack.yaml"
assert_exists "  ... content subdirs created"                   "${PDIR}/knowledge"
assert_exists "  ... firm asset seeded via --include"           "${PDIR}/skills/firm-brief/SKILL.md"
assert_exists "the bundle is staged in workspace/ (company-neutral)" "${BDIR}/pack.json"

seed_pack_content() { # seed_pack_content <version>
  local ver="$1"
  mkdir -p "${PDIR}/skills/status-report" "${PDIR}/knowledge" "${PDIR}/_drafts"
  printf 'house status report skill — v%s\n' "$ver"    > "${PDIR}/skills/status-report/SKILL.md"
  printf 'checklist body v%s\n' "$ver"                 > "${PDIR}/skills/status-report/checklist.md"
  printf 'house tone and formatting rules v%s\n' "$ver" > "${PDIR}/knowledge/house-style.md"
  printf 'scratch, never shipped\n'                    > "${PDIR}/_drafts/notes.md"
  sed -i.bak "s/^version: .*/version: ${ver}/" "${PDIR}/pack.yaml"
  rm -f "${PDIR}/pack.yaml.bak"
}
stage_pack() { # stage_pack <version>
  seed_pack_content "$1"
  run "$CLIENTPACK" scaffold --hq-root "$HQ" --session-company "$FIRM" \
    --firm "$FIRM" --pack "$PACKNAME" --stage-only
}

stage_pack 1.0.0
show "$OUT"
assert_eq "stage-only re-stage exits 0" "0" "$RC"
assert_eq "bundle manifest contents — packName"   "$PACKNAME" "$(jq -r '.packName' "${BDIR}/pack.json")"
assert_eq "bundle manifest contents — sourceFirm" "$FIRM"     "$(jq -r '.sourceFirm' "${BDIR}/pack.json")"
assert_eq "bundle manifest contents — version"    "1.0.0"     "$(jq -r '.version' "${BDIR}/pack.json")"
assert_eq "the bundle carries exactly the 4 content files" "4" \
  "$(find "${BDIR}/content" -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_absent "the pack's _drafts pseudo-dir was never staged" "${BDIR}/content/_drafts"

run "$CLIENTPACK" scaffold --hq-root "$HQ" --session-company "$CLIENT" \
  --firm "$FIRM" --pack "$PACKNAME" --stage-only
assert_eq "a CLIENT-bound session may not scaffold in the firm (exit 1)" "1" "$RC"
assert_has "  ... named error" "$OUT" "E_SESSION_SCOPE"

assert_offline "scaffolding made no external call"

# ===========================================================================
hdr "5  CLIENT-PACK apply — client-bound, manifest describes the bytes"
# ===========================================================================

run "$CLIENTPACK" apply --hq-root "$HQ" --session-company "$CLIENT" \
  --client "$CLIENT" --firm "$FIRM" --pack "$PACKNAME"
show "$OUT"
assert_eq "apply exits 0" "0" "$RC"

MAN="${CODIR}/${MAN_REL}"
assert_exists "manifest written at .hq-packs/{pack}/.hq-pack-manifest.json" "$MAN"
assert_exists "pack content landed in the client company" \
  "${CODIR}/skills/status-report/SKILL.md"
assert_exists "  ... at the same relative path for knowledge too" \
  "${CODIR}/knowledge/house-style.md"
assert_absent "the pack's _drafts pseudo-dir did not land in the client" "${CODIR}/_drafts"

if [ -f "$MAN" ]; then
  assert_eq "manifest contents — sourceFirm"  "$FIRM"     "$(jq -r '.sourceFirm' "$MAN")"
  assert_eq "manifest contents — packName"    "$PACKNAME" "$(jq -r '.packName' "$MAN")"
  assert_eq "manifest contents — version"     "1.0.0"     "$(jq -r '.version' "$MAN")"
  assert_eq "manifest contents — grantedVia.kind" "local-copy" "$(jq -r '.grantedVia.kind // ""' "$MAN")"
  assert_ne "manifest contents — appliedAt is present" "" "$(jq -r '.appliedAt // ""' "$MAN")"
  assert_eq "manifest contents — 4 files recorded" "4" "$(jq -r '.files | length' "$MAN")"

  MISMATCH=0
  CHECKED=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    CHECKED=$((CHECKED + 1))
    recorded="$(jq -r --arg p "$rel" '.files[] | select(.path==$p) | .sha256' "$MAN")"
    actual="$(sha_of "${CODIR}/${rel}")"
    if [ "$recorded" = "$actual" ] && [ -n "$actual" ]; then
      note "sha match  ${actual:0:16}…  ${rel}"
    else
      note "sha MISMATCH ${rel} recorded=${recorded} actual=${actual}"
      MISMATCH=$((MISMATCH + 1))
    fi
  done <<< "$(jq -r '.files[].path' "$MAN")"
  assert_eq "every recorded sha256 matches the copied bytes" "0" "$MISMATCH"
  assert_eq "  ... across all 4 recorded files" "4" "$CHECKED"
else
  bad "no manifest to inspect — every manifest-content assertion is unverifiable"
fi

run "$CLIENTPACK" apply --hq-root "$HQ" --session-company "$CLIENT" \
  --client "$CLIENT" --firm "$FIRM" --pack "$PACKNAME"
assert_eq "re-apply of the same version exits 0" "0" "$RC"
assert_has "  ... and is a no-op" "$OUT" "no-op"
assert_has "  ... writing nothing" "$OUT" "0 written, 0 removed"

assert_offline "apply made no external call"

# ===========================================================================
hdr "6  FORK + UPDATE — a client edit is never overwritten"
# ===========================================================================

FORK_FILE="${CODIR}/skills/status-report/checklist.md"
CLEAN_FILE="${CODIR}/skills/status-report/SKILL.md"
CLIENT_OWN="${CODIR}/knowledge/atlas-only-note.md"

APPLIED_FORK_SHA="$(sha_of "$FORK_FILE")"
printf 'checklist body v1.0.0\nATLAS EDIT: add the safety sign-off step\n' > "$FORK_FILE"
printf 'a note the client wrote themselves\n' > "$CLIENT_OWN"
FORK_SHA_BEFORE="$(sha_of "$FORK_FILE")"
FORK_TEXT_BEFORE="$(cat "$FORK_FILE")"
note "client forked skills/status-report/checklist.md (sha ${FORK_SHA_BEFORE:0:16}…)"

stage_pack 1.1.0
assert_eq "re-stage at v1.1.0 exits 0" "0" "$RC"

run "$CLIENTPACK" update --hq-root "$HQ" --session-company "$CLIENT" \
  --client "$CLIENT" --pack "$PACKNAME"
show "$OUT"
assert_eq "update exits 0" "0" "$RC"
assert_eq "the FORKED file is byte-identical after update" \
  "$FORK_SHA_BEFORE" "$(sha_of "$FORK_FILE")"
assert_eq "  ... and its text is unchanged" "$FORK_TEXT_BEFORE" "$(cat "$FORK_FILE" 2>/dev/null)"
assert_has "  ... the fork is REPORTED, not silently skipped" "$OUT" "FORK-skipped"
assert_has "  ... and named" "$OUT" "skills/status-report/checklist.md"
assert_eq "the UNFORKED sibling did take the new version" \
  "house status report skill — v1.1.0" "$(cat "$CLEAN_FILE" 2>/dev/null)"

if [ -f "$MAN" ]; then
  assert_eq "manifest contents — version bumped to 1.1.0" "1.1.0" "$(jq -r '.version' "$MAN")"
  assert_eq "manifest contents — the fork is marked forked:true" "true" \
    "$(man_field "$MAN" "skills/status-report/checklist.md" forked)"
  assert_eq "manifest contents — the fork keeps its ORIGINAL sha (never adopts the client edit)" \
    "false" "$(man_sha_is "$MAN" "skills/status-report/checklist.md" "$(sha_of "$FORK_FILE")")"
  assert_eq "manifest contents — and that recorded sha is the pre-fork one" \
    "true" "$(man_sha_is "$MAN" "skills/status-report/checklist.md" "$APPLIED_FORK_SHA")"
  assert_eq "manifest contents — the clean file's sha follows the rewritten bytes" \
    "$(sha_of "$CLEAN_FILE")" \
    "$(jq -r '.files[] | select(.path=="skills/status-report/SKILL.md") | .sha256' "$MAN")"
else
  bad "no manifest after update — fork bookkeeping is unverifiable"
fi

# policy hq-auto-select-skips-underscore-pseudo-dirs, live under .hq-packs/
mkdir -p "${CODIR}/.hq-packs/_scratch"
run "$CLIENTPACK" status --hq-root "$HQ" --session-company "$CLIENT" --client "$CLIENT"
assert_eq "status with no --pack auto-selects, ignoring the _scratch pseudo-dir" "0" "$RC"
assert_has "  ... and picks the real pack" "$OUT" "auto-selected pack"
assert_lacks "  ... never naming _scratch" "$OUT" "_scratch"
rmdir "${CODIR}/.hq-packs/_scratch" 2>/dev/null || true

assert_offline "update made no external call"

# ===========================================================================
hdr "7  REMOVE — clean files go, forks and client files stay"
# ===========================================================================

run "$CLIENTPACK" remove --hq-root "$HQ" --session-company "$CLIENT" \
  --client "$CLIENT" --pack "$PACKNAME"
show "$OUT"
assert_eq "remove exits 0" "0" "$RC"
assert_exists "the FORKED file survives remove"            "$FORK_FILE"
assert_exists "the client's OWN file survives remove"      "$CLIENT_OWN"
assert_exists "the client company's own scaffold survives" "${CODIR}/handover-checklist.md"
assert_absent "the unforked pack file is gone"             "$CLEAN_FILE"
assert_absent "the other unforked pack file is gone"       "${CODIR}/knowledge/house-style.md"
assert_has    "the fork is reported as kept"               "$OUT" "FORK-kept"
if [ -e "$FORK_FILE" ]; then
  assert_eq "the forked bytes are still byte-identical after remove" \
    "$FORK_SHA_BEFORE" "$(sha_of "$FORK_FILE")"
fi

if [ -f "$MAN" ]; then
  assert_eq "manifest contents — retained because a fork survived" \
    "removed-with-retained-forks" "$(jq -r '.state // ""' "$MAN")"
  assert_eq "manifest contents — the retained entry is the fork" \
    "true" "$(man_field "$MAN" "skills/status-report/checklist.md" retainedOnRemove)"
  assert_eq "manifest contents — the deleted clean files are no longer claimed" \
    "absent" "$(man_field "$MAN" "skills/status-report/SKILL.md" sha256)"
  assert_ne "manifest contents — removedAt recorded" "" "$(jq -r '.removedAt // ""' "$MAN")"
else
  bad "the manifest was deleted even though a fork was retained"
fi

assert_offline "remove made no external call"

# ===========================================================================
hdr "8  THE REAL PACK WAS NOT TOUCHED"
# ===========================================================================

REAL_PACK_AFTER="$(tree_sha "$PACK")"
if [ "$REAL_PACK_BEFORE" = "$REAL_PACK_AFTER" ]; then
  ok "every file under ${PACK} is byte-identical to before this run"
else
  bad "the real pack tree CHANGED during the run:"
  show "$(diff <(printf '%s\n' "$REAL_PACK_BEFORE") <(printf '%s\n' "$REAL_PACK_AFTER") 2>&1 || true)"
fi
if [ -n "$SEED_FAULT" ]; then
  if grep -q 'SEEDED FAULT' "${PACK}/scripts/client-pack.sh" 2>/dev/null; then
    bad "the seeded fault leaked into the REAL ${PACK}/scripts/client-pack.sh"
  else
    ok "the seeded fault lives only in the fixture copy — the real client-pack.sh is clean"
  fi
fi

# ===========================================================================
hdr "SUMMARY"
# ===========================================================================

printf '  assertions passed : %d\n' "$PASSES"
printf '  assertions failed : %d\n' "$FAILS"
[ -n "$SEED_FAULT" ] && printf '  seeded fault      : %s\n' "$SEED_FAULT"

if [ "$FAILS" -gt 0 ]; then
  printf 'E2E SMOKE FAILED — %d assertion(s) failed (see the FAIL lines above)\n' "$FAILS"
  exit 1
fi
if [ -n "$SEED_FAULT" ]; then
  printf 'E2E SMOKE PASSED WITH A SEEDED FAULT — the fault was not detected.\n'
  printf 'That is itself a failure of the harness: a smoke that cannot go red is worthless.\n'
  exit 1
fi
printf 'E2E SMOKE PASSED — %d assertions, whole arc, zero external calls.\n' "$PASSES"
exit 0
