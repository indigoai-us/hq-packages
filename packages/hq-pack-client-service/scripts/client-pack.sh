#!/usr/bin/env bash
# client-pack.sh — firm packs delivered into client companies by copy-with-provenance.
#
#   client-pack.sh scaffold --firm <slug> --pack <name> [--version <v>]
#                           [--include <type>/<name> ...] [--stage-only]
#   client-pack.sh apply    --client <slug> (--bundle <dir> | --firm <slug> --pack <name>)
#   client-pack.sh update   --client <slug> --pack <name> [--bundle <dir>]
#   client-pack.sh remove   --client <slug> --pack <name>
#   client-pack.sh status   --client <slug> --pack <name>          # read-only diagnostic
#
# Common options
#   --hq-root <path>          HQ root (default: four levels above this script)
#   --session-company <slug>  the company THIS session is bound to (see "Session binding")
#   --dry-run                 plan only; write nothing
#   --force                   apply: reconcile even when the same version is already applied
#
# Exit codes
#   0  operation completed (forks reported as forks is a normal, successful outcome)
#   1  operation refused or failed — nothing destructive was done
#   2  usage / environment problem
#
# ---------------------------------------------------------------------------
# Design notes — read these before changing anything
# ---------------------------------------------------------------------------
#
# 1. TWO SESSIONS, NEVER ONE (policy client-service-materialize-not-mount)
#    `scaffold` runs in a session bound to the FIRM and writes a portable bundle
#    into workspace/ (a non-company path). `apply`/`update`/`remove` run in a
#    session bound to the CLIENT and read only that bundle plus the client tree.
#    No verb ever reads companies/{firm}/ while writing companies/{client}/.
#    `sourceFirm` in the manifest is provenance metadata — it is NEVER used as a
#    path to read at client runtime. This is why the tool works with the
#    mandatory-scope-authorizer gate instead of around it.
#
# 2. FORK PRESERVATION IS THE SAFETY PROPERTY
#    A manifest-owned file whose current sha256 differs from the sha recorded at
#    apply time is a FORK: the client edited it. Forks are skipped by `update`,
#    kept by `remove`, and reported by both. A fork's manifest entry keeps its
#    ORIGINAL applied sha forever — adopting the client's sha would make the fork
#    look clean on the next pass and get it deleted. That single rule is the
#    difference between safe and catastrophic.
#
# 3. ABSENT IS UNKNOWN (policy hq-absent-field-never-means-constraining-value)
#    A missing `sha256`, a null sha, a non-hex sha, a missing `version`, a missing
#    `grantedVia`, or a missing manifest are all UNKNOWN. Unknown never resolves
#    to "unchanged", "same version", or "safe to delete". Presence is read with
#    `has(key)`; the value is only consulted afterwards. Every unknown resolves in
#    the direction that PRESERVES client data.
#
# 4. UNDERSCORE PSEUDO-DIRS (policy hq-auto-select-skips-underscore-pseudo-dirs)
#    Every auto-selection from a directory listing goes through
#    `list_selectable_dirs`, which drops `_`-prefixed entries by a general rule.
#
# 5. SET -E STATUS RETURNS (policy hq-bash-set-e-status-returns)
#    Functions that return non-zero as a status signal are only called inside an
#    `if`/`&&` condition or with the `|| rc=$?` capture idiom, never bare.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

MANIFEST_BASENAME=".hq-pack-manifest.json"
MANIFEST_DIRNAME=".hq-packs"
MANIFEST_SCHEMA="hq-pack-manifest"
MANIFEST_SCHEMA_VERSION=1

HQ_ROOT="${HQ_ROOT:-}"
SESSION_COMPANY="${HQ_CLIENT_PACK_SESSION_COMPANY:-}"
DRY_RUN=0
FORCE=0
VERB=""
FIRM=""
CLIENT=""
PACK=""
VERSION=""
BUNDLE=""
INCLUDES=""
STAGE_ONLY=0

TMPDIR_SELF=""
cleanup() { [ -n "$TMPDIR_SELF" ] && rm -rf "$TMPDIR_SELF"; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# output / errors
# ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
line() { printf '  %-22s %s\n' "$1" "$2"; }
# In --dry-run every mutating label is a plan, and says so.
plabel() { if [ "$DRY_RUN" -eq 1 ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
sumpfx() { if [ "$DRY_RUN" -eq 1 ]; then printf 'PLAN   '; else printf 'OK     '; fi; }

die_usage() { printf 'ERROR  %s  %s\n' "$1" "$2" >&2; exit 2; }
die_op()    { printf 'ERROR  %s  %s\n' "$1" "$2" >&2; exit 1; }

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sha_of() { # sha_of <file> -> 64-hex, or empty when unreadable
  local f="$1" out rc=0
  [ -f "$f" ] || { printf ''; return 0; }
  out="$(shasum -a 256 -- "$f" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || { printf ''; return 0; }
  printf '%s' "${out%% *}"
}

is_sha() { # is_sha <string> — PRESENCE of a usable value, not just non-empty
  printf '%s' "${1:-}" | grep -Eq '^[0-9a-f]{64}$'
}

is_slug() { printf '%s' "${1:-}" | grep -Eq '^[a-z0-9][a-z0-9-]{0,63}$'; }

# Policy hq-auto-select-skips-underscore-pseudo-dirs: general leading-underscore
# exclusion, never a named special case. Used by EVERY auto-selection here.
list_selectable_dirs() { # list_selectable_dirs <parent> -> names, one per line
  local parent="$1" entry name
  [ -d "$parent" ] || return 0
  for entry in "$parent"/*/; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    case "$name" in
      _*) continue ;;                       # _template, _archive, _shared, ...
      README|README.md) continue ;;
    esac
    printf '%s\n' "$name"
  done
}

# Content paths must stay inside the client company and must never claim the
# provenance directory itself.
path_is_safe() { # path_is_safe <relpath>
  local p="$1"
  case "$p" in
    /*|*/../*|../*|*/..|..) return 1 ;;
    "${MANIFEST_DIRNAME}"/*|"${MANIFEST_DIRNAME}") return 1 ;;
    "") return 1 ;;
  esac
  return 0
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die_usage "E_ENV_JQ_MISSING" "jq is required"
  command -v shasum >/dev/null 2>&1 || die_usage "E_ENV_SHASUM_MISSING" "shasum is required"
}

# ---------------------------------------------------------------------------
# session binding — an unknown binding is NEVER treated as authorization
# ---------------------------------------------------------------------------

# shellcheck source=lib/session-lock.sh
. "${SCRIPT_DIR}/lib/session-lock.sh"

resolve_session_company() { # prints the session's lock set (comma list), or empty
  session_lock_companies "$HQ_ROOT" "$SESSION_COMPANY"
}

require_session_bound_to() { # require_session_bound_to <slug> <what>
  local want="$1" what="$2" got
  got="$(resolve_session_company)"
  if [ -z "$got" ]; then
    die_op "E_SESSION_UNKNOWN" \
"cannot determine which company this session is bound to, so writes to ${what} '${want}' are refused.
       Unknown is not authorization. Bind the session
       (core/scripts/hq-session.sh set company_slug ${want}) or state it explicitly
       with --session-company ${want} when running outside a session."
  fi
  if ! session_lock_includes "$got" "$want"; then
    die_op "E_SESSION_SCOPE" \
"this session is locked to '${got}' but the operation writes into ${what} '${want}'.
       Firm packs are materialized, not mounted: scaffold in a session locked to the
       firm; apply/update/remove in a session that holds the CLIENT company (bound
       to it, or added with core/scripts/hq-session.sh add company ${want})."
  fi
}

# ---------------------------------------------------------------------------
# bundle (the portable, company-neutral staging form)
# ---------------------------------------------------------------------------

default_bundle_dir() { # default_bundle_dir <firm> <pack>
  printf '%s/workspace/pack-staging/%s/%s' "$HQ_ROOT" "$1" "$2"
}

bundle_field() { # bundle_field <bundle> <key> -> value or empty
  local b="$1" k="$2"
  [ -f "${b}/pack.json" ] || { printf ''; return 0; }
  jq -r --arg k "$k" 'if has($k) then (.[$k] // "") else "" end' "${b}/pack.json" 2>/dev/null || printf ''
}

bundle_files() { # bundle_files <bundle> -> content-relative paths, sorted
  local b="$1"
  [ -d "${b}/content" ] || return 0
  ( cd "${b}/content" && find . \( -type f -o -type l \) -print 2>/dev/null ) \
    | sed 's|^\./||' | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# manifest
# ---------------------------------------------------------------------------

manifest_path() { # manifest_path <client-dir> <pack>
  printf '%s/%s/%s/%s' "$1" "$MANIFEST_DIRNAME" "$2" "$MANIFEST_BASENAME"
}

manifest_field() { # manifest_field <manifest> <key> -> value, empty when ABSENT
  local m="$1" k="$2"
  [ -f "$m" ] || { printf ''; return 0; }
  jq -r --arg k "$k" 'if has($k) then (.[$k] // "") else "" end' "$m" 2>/dev/null || printf ''
}

manifest_entry() { # manifest_entry <manifest> <path> -> entry json, empty when absent
  local m="$1" p="$2" out rc=0
  [ -f "$m" ] || { printf ''; return 0; }
  out="$(jq -c --arg p "$p" '
    if (.files? | type) == "array"
    then (first(.files[] | select(type == "object" and (.path? // "") == $p)) // empty)
    else empty end' "$m" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || out=""
  printf '%s' "$out"
}

manifest_paths() { # manifest_paths <manifest> -> owned paths, sorted
  local m="$1"
  [ -f "$m" ] || return 0
  jq -r 'if (.files? | type) == "array"
         then (.files[] | select(type == "object" and has("path") and (.path | type) == "string" and .path != "") | .path)
         else empty end' "$m" 2>/dev/null | LC_ALL=C sort
}

# entry_sha <entry-json> -> the recorded sha, or empty when ABSENT/null/unusable.
# Presence and value are read separately; an unusable sha yields "" and every
# caller treats "" as UNKNOWN, never as "matches" and never as "safe to delete".
entry_sha() {
  local e="${1:-}" v
  [ -n "$e" ] || { printf ''; return 0; }
  v="$(printf '%s' "$e" | jq -r 'if has("sha256") then (.sha256 // "") else "" end' 2>/dev/null)" || v=""
  if is_sha "$v"; then printf '%s' "$v"; else printf ''; fi
}

# classify <client-dir> <manifest> <relpath> -> one of:
#   clean        manifest-owned, sha recorded, file present, content matches
#   fork         manifest-owned, sha recorded, file present, content differs
#   unknown-sha  manifest-owned, sha ABSENT/null/malformed  -> preserve
#   missing      manifest-owned, file not present in the client
#   unowned      not in the manifest at all
classify() {
  local cdir="$1" man="$2" rel="$3" entry msha cur
  entry="$(manifest_entry "$man" "$rel")"
  [ -n "$entry" ] || { printf 'unowned'; return 0; }
  if [ ! -e "${cdir}/${rel}" ]; then printf 'missing'; return 0; fi
  msha="$(entry_sha "$entry")"
  if [ -z "$msha" ]; then printf 'unknown-sha'; return 0; fi
  cur="$(sha_of "${cdir}/${rel}")"
  if [ -z "$cur" ]; then printf 'unknown-sha'; return 0; fi
  if [ "$cur" = "$msha" ]; then printf 'clean'; else printf 'fork'; fi
}

copy_in() { # copy_in <src> <dest>
  [ "$DRY_RUN" -eq 1 ] && return 0
  mkdir -p "$(dirname "$2")"
  cp -p -- "$1" "$2"
}

prune_empty_parents() { # prune_empty_parents <root> <relpath>
  local root="$1" dir
  dir="$(dirname "$2")"
  while [ "$dir" != "." ] && [ "$dir" != "/" ] && [ -n "$dir" ]; do
    [ -d "${root}/${dir}" ] || break
    rmdir "${root}/${dir}" 2>/dev/null || break
    dir="$(dirname "$dir")"
  done
  return 0
}

# ---------------------------------------------------------------------------
# verb: scaffold  (runs in a session bound to the FIRM)
# ---------------------------------------------------------------------------

do_scaffold() {
  [ -n "$FIRM" ] || die_usage "E_USAGE" "scaffold requires --firm <slug>"
  [ -n "$PACK" ] || die_usage "E_USAGE" "scaffold requires --pack <name>"
  is_slug "$FIRM" || die_usage "E_USAGE" "invalid firm slug: ${FIRM}"
  is_slug "$PACK" || die_usage "E_USAGE" "invalid pack name: ${PACK}"
  require_session_bound_to "$FIRM" "firm"

  local firm_dir="${HQ_ROOT}/companies/${FIRM}"
  [ -d "$firm_dir" ] || die_op "E_FIRM_NOT_FOUND" "no company at ${firm_dir}"

  local pdir="${firm_dir}/packs/${PACK}"
  say "client-pack scaffold — firm=${FIRM} pack=${PACK}"

  if [ "$STAGE_ONLY" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      mkdir -p "${pdir}/skills" "${pdir}/knowledge" "${pdir}/workers" "${pdir}/policies"
    fi
    if [ ! -f "${pdir}/pack.yaml" ] && [ "$DRY_RUN" -eq 0 ]; then
      cat > "${pdir}/pack.yaml" <<YAML
# Firm pack — authored by ${FIRM}, materialized into client companies by
# core/packages/hq-pack-client-service/scripts/client-pack.sh
name: ${PACK}
sourceFirm: ${FIRM}
version: ${VERSION:-0.1.0}
description: ""
YAML
      line "created" "companies/${FIRM}/packs/${PACK}/pack.yaml"
    fi
    # Content subdirs mirror company scope 1:1; a file at
    # packs/{pack}/skills/x/SKILL.md lands at companies/{client}/skills/x/SKILL.md.
    if [ "$DRY_RUN" -eq 0 ]; then
      [ -f "${pdir}/README.md" ] || cat > "${pdir}/README.md" <<MD
# ${PACK} — firm pack (${FIRM})

Content under \`skills/\`, \`knowledge/\`, \`workers/\`, \`policies/\` is copied
verbatim into a client company at the same relative path.

Delivery is **copy-with-provenance**, never a mount. Run \`scaffold --stage-only\`
in a firm-bound session to refresh the portable bundle, then \`apply\` in a session
bound to the client company.
MD
    fi
    line "ready" "companies/${FIRM}/packs/${PACK}/"

    # --include <type>/<name>: seed from the firm's own assets.
    local inc src dst
    while IFS= read -r inc; do
      [ -n "$inc" ] || continue
      src="${firm_dir}/${inc}"
      dst="${pdir}/${inc}"
      if [ ! -e "$src" ]; then
        line "include-missing" "$inc"
        continue
      fi
      if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$(dirname "$dst")"
        cp -Rp -- "$src" "$dst"
      fi
      line "included" "$inc"
    done <<< "$INCLUDES"
  fi

  # ---- stage the portable bundle into workspace/ (company-neutral) ----------
  local ver desc
  ver="$VERSION"
  if [ -z "$ver" ] && [ -f "${pdir}/pack.yaml" ]; then
    ver="$(sed -n 's/^version:[[:space:]]*//p' "${pdir}/pack.yaml" | head -1 | tr -d '"'"'"' ')"
  fi
  # ABSENT version is UNKNOWN, not "0" and not "same as whatever is installed".
  [ -n "$ver" ] || die_op "E_PACK_VERSION_MISSING" \
    "packs/${PACK}/pack.yaml declares no version; refusing to stage an unversioned bundle"
  desc="$(sed -n 's/^description:[[:space:]]*//p' "${pdir}/pack.yaml" 2>/dev/null | head -1)"

  local bdir; bdir="$(default_bundle_dir "$FIRM" "$PACK")"
  local n=0 rel sub
  if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf "$bdir"
    mkdir -p "${bdir}/content"
  fi
  for sub in skills knowledge workers policies scripts; do
    [ -d "${pdir}/${sub}" ] || continue
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ -L "${pdir}/${sub}/${rel}" ]; then
        die_op "E_BUNDLE_SYMLINK" \
"packs/${PACK}/${sub}/${rel} is a symlink. A symlink can resolve back into the firm
       vault at client runtime, which is the mount this pack exists to avoid.
       Replace it with a real file."
      fi
      path_is_safe "${sub}/${rel}" || die_op "E_UNSAFE_PATH" "${sub}/${rel}"
      copy_in "${pdir}/${sub}/${rel}" "${bdir}/content/${sub}/${rel}"
      n=$((n + 1))
    done <<< "$( ( cd "${pdir}/${sub}" && find . \( -type f -o -type l \) -print 2>/dev/null ) | sed 's|^\./||' | LC_ALL=C sort )"
  done

  if [ "$DRY_RUN" -eq 0 ]; then
    jq -n --arg n "$PACK" --arg f "$FIRM" --arg v "$ver" --arg d "${desc:-}" --arg t "$(now_iso)" \
      '{packName:$n, sourceFirm:$f, version:$v, description:$d, stagedAt:$t}' \
      > "${bdir}/pack.json"
  fi
  line "staged" "workspace/pack-staging/${FIRM}/${PACK} (${n} file(s), v${ver})"
  say ""
  say "Next: bind a session to the CLIENT company, then"
  say "  client-pack.sh apply --client <slug> --firm ${FIRM} --pack ${PACK}"
}

# ---------------------------------------------------------------------------
# shared resolution for the client-side verbs
# ---------------------------------------------------------------------------

CLIENT_DIR=""
MANIFEST=""

resolve_client() {
  [ -n "$CLIENT" ] || die_usage "E_USAGE" "${VERB} requires --client <slug>"
  is_slug "$CLIENT" || die_usage "E_USAGE" "invalid client slug: ${CLIENT}"
  CLIENT_DIR="${HQ_ROOT}/companies/${CLIENT}"
  [ -d "$CLIENT_DIR" ] || die_op "E_CLIENT_NOT_FOUND" "no company at ${CLIENT_DIR}"
  require_session_bound_to "$CLIENT" "client company"

  if [ -z "$PACK" ]; then
    # Auto-select only when exactly one pack is applied, and never pick up a
    # `_`-prefixed pseudo-dir (policy hq-auto-select-skips-underscore-pseudo-dirs).
    local cands count
    cands="$(list_selectable_dirs "${CLIENT_DIR}/${MANIFEST_DIRNAME}")"
    count="$(printf '%s' "$cands" | grep -c . || true)"
    if [ "$count" = "1" ]; then
      PACK="$(printf '%s\n' "$cands" | head -1)"
      line "auto-selected pack" "$PACK"
    else
      die_usage "E_USAGE" "${VERB} requires --pack <name> (${count} applied pack(s) found)"
    fi
  fi
  is_slug "$PACK" || die_usage "E_USAGE" "invalid pack name: ${PACK}"
  MANIFEST="$(manifest_path "$CLIENT_DIR" "$PACK")"
}

resolve_bundle() { # resolve_bundle <firm-hint>
  local firm="${1:-}"
  if [ -z "$BUNDLE" ]; then
    [ -n "$firm" ] || die_usage "E_USAGE" "no --bundle and no source firm to derive one from"
    BUNDLE="$(default_bundle_dir "$firm" "$PACK")"
  fi
  [ -d "$BUNDLE" ] || die_op "E_BUNDLE_MISSING" \
"no staged bundle at ${BUNDLE}.
       Stage it in a FIRM-bound session: client-pack.sh scaffold --firm <firm> --pack ${PACK} --stage-only
       Refusing to proceed — an unavailable bundle is unknown, not 'nothing to install'."
  [ -f "${BUNDLE}/pack.json" ] || die_op "E_BUNDLE_DESCRIPTOR_MISSING" "no pack.json in ${BUNDLE}"
}

# write_manifest <files-json> <version> <appliedAt> [extra-json]
write_manifest() {
  local files="$1" ver="$2" applied="$3" extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  [ "$DRY_RUN" -eq 1 ] && return 0
  mkdir -p "$(dirname "$MANIFEST")"
  jq -n \
    --arg schema "$MANIFEST_SCHEMA" \
    --argjson sv "$MANIFEST_SCHEMA_VERSION" \
    --arg firm "$SOURCE_FIRM" \
    --arg pack "$PACK" \
    --arg ver "$ver" \
    --arg applied "$applied" \
    --argjson files "$files" \
    --argjson extra "$extra" \
    '{schema:$schema, schemaVersion:$sv, sourceFirm:$firm, packName:$pack,
      version:$ver, appliedAt:$applied, files:$files} + $extra' > "$MANIFEST"
}

SOURCE_FIRM=""

# ---------------------------------------------------------------------------
# verb: apply / update  (one engine, two entry conditions)
# ---------------------------------------------------------------------------

do_apply_or_update() {
  local mode="$1"      # apply | update
  resolve_client

  local had_manifest=0
  [ -f "$MANIFEST" ] && had_manifest=1

  if [ "$mode" = "update" ] && [ "$had_manifest" -eq 0 ]; then
    die_op "E_NO_MANIFEST" \
"no ${MANIFEST_BASENAME} for pack '${PACK}' in company '${CLIENT}'.
       A missing manifest is UNKNOWN ownership, never 'nothing is owned' — update
       refuses rather than guessing which files it may rewrite. Use apply."
  fi

  local firm_hint="$FIRM"
  if [ -z "$firm_hint" ] && [ "$had_manifest" -eq 1 ]; then
    # Provenance only: this names the firm, it does NOT open a path to its vault.
    firm_hint="$(manifest_field "$MANIFEST" "sourceFirm")"
  fi
  resolve_bundle "$firm_hint"

  local b_version b_firm
  b_version="$(bundle_field "$BUNDLE" "version")"
  b_firm="$(bundle_field "$BUNDLE" "sourceFirm")"
  [ -n "$b_version" ] || die_op "E_BUNDLE_VERSION_MISSING" \
    "bundle declares no version — unknown, refusing (cannot reason about idempotency)"
  SOURCE_FIRM="${b_firm:-$firm_hint}"
  [ -n "$SOURCE_FIRM" ] || die_op "E_SOURCE_FIRM_UNKNOWN" "bundle declares no sourceFirm"

  say "client-pack ${mode} — client=${CLIENT} pack=${PACK} v${b_version} from=${SOURCE_FIRM}"
  [ "$DRY_RUN" -eq 1 ] && say "  (dry run — nothing will be written)"

  # ---- idempotency: same version already applied is a no-op -----------------
  if [ "$mode" = "apply" ] && [ "$had_manifest" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
    local cur_ver; cur_ver="$(manifest_field "$MANIFEST" "version")"
    # ABSENT version is UNKNOWN — it is NOT "the same version", so it does not
    # short-circuit into a no-op; it falls through to the fork-safe reconcile.
    if [ -n "$cur_ver" ] && [ "$cur_ver" = "$b_version" ]; then
      line "no-op" "v${b_version} already applied (re-apply is idempotent)"
      say "$(sumpfx)0 written, 0 removed"
      return 0
    fi
  fi

  TMPDIR_SELF="${TMPDIR_SELF:-$(mktemp -d)}"
  local newfiles="${TMPDIR_SELF}/files.jsonl"
  : > "$newfiles"

  local n_written=0 n_forks=0 n_kept=0 n_added=0 n_unchanged=0
  local rel state entry msha bsha

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if ! path_is_safe "$rel"; then
      line "unsafe-skipped" "$rel"
      continue
    fi
    if [ -L "${BUNDLE}/content/${rel}" ]; then
      line "symlink-skipped" "$rel"
      continue
    fi
    bsha="$(sha_of "${BUNDLE}/content/${rel}")"
    state="$(classify "$CLIENT_DIR" "$MANIFEST" "$rel")"
    entry="$(manifest_entry "$MANIFEST" "$rel")"
    msha="$(entry_sha "$entry")"

    case "$state" in
      unowned)
        if [ -e "${CLIENT_DIR}/${rel}" ]; then
          # A pre-existing client file the pack never owned. Never adopt it,
          # never overwrite it.
          line "collision-kept" "$rel"
          n_kept=$((n_kept + 1))
        else
          copy_in "${BUNDLE}/content/${rel}" "${CLIENT_DIR}/${rel}"
          printf '%s\n' "$(jq -nc --arg p "$rel" --arg s "$bsha" --arg v "$b_version" \
            '{path:$p, sha256:$s, appliedVersion:$v}')" >> "$newfiles"
          line "$(plabel added would-add)" "$rel"
          n_added=$((n_added + 1)); n_written=$((n_written + 1))
        fi
        ;;
      clean)
        if [ "$msha" = "$bsha" ]; then
          printf '%s\n' "$(jq -nc --arg p "$rel" --arg s "$msha" --arg v "$b_version" \
            '{path:$p, sha256:$s, appliedVersion:$v}')" >> "$newfiles"
          n_unchanged=$((n_unchanged + 1))
        else
          copy_in "${BUNDLE}/content/${rel}" "${CLIENT_DIR}/${rel}"
          printf '%s\n' "$(jq -nc --arg p "$rel" --arg s "$bsha" --arg v "$b_version" \
            '{path:$p, sha256:$s, appliedVersion:$v}')" >> "$newfiles"
          line "$(plabel updated would-rewrite)" "$rel"
          n_written=$((n_written + 1))
        fi
        ;;
      fork)
        # THE rule: keep the ORIGINAL applied sha. Adopting the client's current
        # sha would make this file look clean next pass and get it deleted.
        printf '%s\n' "$(jq -nc --arg p "$rel" --arg s "$msha" \
          --arg v "$(printf '%s' "$entry" | jq -r '.appliedVersion? // ""')" --arg t "$(now_iso)" \
          '{path:$p, sha256:$s, appliedVersion:$v, forked:true, forkedDetectedAt:$t}')" >> "$newfiles"
        line "FORK-skipped" "$rel"
        n_forks=$((n_forks + 1))
        ;;
      unknown-sha)
        printf '%s\n' "$(printf '%s' "$entry" | jq -c '. + {forked:true, forkReason:"sha-unknown"}')" >> "$newfiles"
        line "FORK-skipped(unknown-sha)" "$rel"
        n_forks=$((n_forks + 1))
        ;;
      missing)
        # The client deleted a pack file. That is a client decision; update does
        # not resurrect it, and it stays owned so `remove` stays a no-op for it.
        printf '%s\n' "$(printf '%s' "$entry" | jq -c '.')" >> "$newfiles"
        line "client-deleted-kept" "$rel"
        n_kept=$((n_kept + 1))
        ;;
    esac
  done <<< "$(bundle_files "$BUNDLE")"

  # ---- manifest-owned files that are no longer in the bundle ---------------
  # Retired from the pack. They are LEFT IN PLACE and dropped from the manifest:
  # the pack stops claiming them, and nothing is deleted. `remove` is the only
  # verb that deletes, and it can no longer reach them.
  local owned
  while IFS= read -r owned; do
    [ -n "$owned" ] || continue
    if [ ! -e "${BUNDLE}/content/${owned}" ]; then
      line "retired-left-in-place" "$owned"
      n_kept=$((n_kept + 1))
    fi
  done <<< "$(manifest_paths "$MANIFEST")"

  local files_json applied
  files_json="$(jq -sc '.' "$newfiles")"
  applied="$(now_iso)"

  # grantedVia: the delivery path this record came through. The portfolio
  # entitlement record uses the same key for a cloud subscription. A reader must
  # treat an ABSENT grantedVia as unknown provenance, never as "local-copy".
  local extra
  extra="$(jq -nc --arg k "local-copy" --arg b "${BUNDLE#${HQ_ROOT}/}" --arg s "$(bundle_field "$BUNDLE" 'stagedAt')" \
    '{grantedVia:{kind:$k, bundle:$b, stagedAt:$s}}')"
  write_manifest "$files_json" "$b_version" "$applied" "$extra"

  say "$(sumpfx)${n_written} written (${n_added} new), ${n_unchanged} unchanged, ${n_forks} fork(s) preserved, ${n_kept} other file(s) kept"
  [ "$n_forks" -gt 0 ] && say "       forks are client edits — they were NOT overwritten and stay owned-but-forked"
  return 0
}

# ---------------------------------------------------------------------------
# verb: remove
# ---------------------------------------------------------------------------

do_remove() {
  resolve_client

  [ -f "$MANIFEST" ] || die_op "E_NO_MANIFEST" \
"no ${MANIFEST_BASENAME} for pack '${PACK}' in company '${CLIENT}'.
       Without a manifest nothing is known to be pack-owned, and 'unknown' never
       resolves to 'safe to delete'. Refusing to delete anything."

  SOURCE_FIRM="$(manifest_field "$MANIFEST" "sourceFirm")"
  local ver; ver="$(manifest_field "$MANIFEST" "version")"
  say "client-pack remove — client=${CLIENT} pack=${PACK}${ver:+ v${ver}} from=${SOURCE_FIRM:-<unknown>}"
  [ "$DRY_RUN" -eq 1 ] && say "  (dry run — nothing will be deleted)"

  TMPDIR_SELF="${TMPDIR_SELF:-$(mktemp -d)}"
  local retained="${TMPDIR_SELF}/retained.jsonl"
  : > "$retained"

  local n_removed=0 n_forks=0 n_unknown=0 n_absent=0
  local rel state entry

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if ! path_is_safe "$rel"; then
      line "unsafe-skipped" "$rel"
      continue
    fi
    state="$(classify "$CLIENT_DIR" "$MANIFEST" "$rel")"
    entry="$(manifest_entry "$MANIFEST" "$rel")"
    case "$state" in
      clean)
        if [ "$DRY_RUN" -eq 0 ]; then
          rm -f -- "${CLIENT_DIR}/${rel}"
          prune_empty_parents "$CLIENT_DIR" "$rel"
        fi
        line "$(plabel removed would-remove)" "$rel"
        n_removed=$((n_removed + 1))
        ;;
      fork)
        printf '%s\n' "$(printf '%s' "$entry" | jq -c '. + {forked:true, retainedOnRemove:true}')" >> "$retained"
        line "FORK-kept" "$rel"
        n_forks=$((n_forks + 1))
        ;;
      unknown-sha)
        printf '%s\n' "$(printf '%s' "$entry" | jq -c '. + {forked:true, forkReason:"sha-unknown", retainedOnRemove:true}')" >> "$retained"
        line "KEPT(unknown-sha)" "$rel"
        n_unknown=$((n_unknown + 1))
        ;;
      missing)
        line "already-absent" "$rel"
        n_absent=$((n_absent + 1))
        ;;
      unowned)
        line "not-owned-kept" "$rel"
        ;;
    esac
  done <<< "$(manifest_paths "$MANIFEST")"

  # Entries with no usable `path` are counted, never acted on.
  local badpaths
  badpaths="$(jq -r 'if (.files? | type) == "array"
      then ([.files[] | select((type != "object") or (has("path") | not) or ((.path? | type) != "string") or (.path == ""))] | length)
      else 0 end' "$MANIFEST" 2>/dev/null || printf '0')"
  [ "${badpaths:-0}" -gt 0 ] && line "entries-without-path" "${badpaths} (ignored, nothing deleted)"

  local kept_total=$((n_forks + n_unknown))
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$kept_total" -eq 0 ]; then
      rm -f -- "$MANIFEST"
      rmdir "$(dirname "$MANIFEST")" 2>/dev/null || true
      rmdir "${CLIENT_DIR}/${MANIFEST_DIRNAME}" 2>/dev/null || true
    else
      local files_json
      files_json="$(jq -sc '.' "$retained")"
      write_manifest "$files_json" "${ver}" "$(manifest_field "$MANIFEST" 'appliedAt')" \
        "$(jq -nc --arg t "$(now_iso)" '{removedAt:$t, state:"removed-with-retained-forks"}')"
    fi
  fi

  say "$(sumpfx)${n_removed} removed, ${n_forks} fork(s) kept, ${n_unknown} unknown-sha file(s) kept, ${n_absent} already absent"
  say "       client-created files were never in scope and were not touched"
  return 0
}

# ---------------------------------------------------------------------------
# verb: status (read-only)
# ---------------------------------------------------------------------------

do_status() {
  resolve_client
  [ -f "$MANIFEST" ] || die_op "E_NO_MANIFEST" "no ${MANIFEST_BASENAME} for pack '${PACK}' in '${CLIENT}'"
  say "client-pack status — client=${CLIENT} pack=${PACK} v$(manifest_field "$MANIFEST" 'version') from=$(manifest_field "$MANIFEST" 'sourceFirm')"
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    line "$(classify "$CLIENT_DIR" "$MANIFEST" "$rel")" "$rel"
  done <<< "$(manifest_paths "$MANIFEST")"
}

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------

[ $# -gt 0 ] || die_usage "E_USAGE" "no verb given (scaffold|apply|update|remove|status)"
VERB="$1"; shift

while [ $# -gt 0 ]; do
  case "$1" in
    --firm)            FIRM="${2:-}"; shift 2 ;;
    --client)          CLIENT="${2:-}"; shift 2 ;;
    --pack)            PACK="${2:-}"; shift 2 ;;
    --version)         VERSION="${2:-}"; shift 2 ;;
    --bundle)          BUNDLE="${2:-}"; shift 2 ;;
    --hq-root)         HQ_ROOT="${2:-}"; shift 2 ;;
    --session-company) SESSION_COMPANY="${2:-}"; shift 2 ;;
    --include)         INCLUDES="${INCLUDES}${2:-}"$'\n'; shift 2 ;;
    --stage-only)      STAGE_ONLY=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --force)           FORCE=1; shift ;;
    -h|--help)         sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                 die_usage "E_USAGE" "unknown argument: $1" ;;
  esac
done

require_jq
if [ -z "$HQ_ROOT" ]; then
  HQ_ROOT="$(cd -- "${PACK_DIR}/../../.." && pwd)"
fi
[ -d "${HQ_ROOT}/companies" ] || die_usage "E_ENV_HQ_ROOT" "no companies/ under HQ root ${HQ_ROOT}"

case "$VERB" in
  scaffold) do_scaffold ;;
  apply)    do_apply_or_update apply ;;
  update)   do_apply_or_update update ;;
  remove)   do_remove ;;
  status)   do_status ;;
  *)        die_usage "E_USAGE" "unknown verb: ${VERB}" ;;
esac
