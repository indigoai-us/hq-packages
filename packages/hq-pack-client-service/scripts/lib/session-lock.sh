#!/usr/bin/env bash
# session-lock.sh: read which companies the current HQ session is locked to.
#
# Sourced by new-client.sh, client-pack.sh and handover-client.sh. One
# implementation so the three engines cannot drift.
#
# A session is locked to one company by default. On hq-core with multi-company
# session locks (hooks.multi-company-session-lock), a session can hold several:
# the primary plus companies added with `hq-session.sh add company <slug>`.
# A phase may write into a company only if that company is in the lock set.
#
# Unknown is never authorization: if the lock set cannot be read, the result is
# empty and callers refuse.

# session_lock_companies <hq_root> <explicit>
#   Prints the lock set as a comma-separated list, primary first, or nothing.
#   <explicit> is the --session-company value (one slug or a comma list); when
#   set it wins, for running outside a session (CI, fixtures).
session_lock_companies() {
  local root="$1" explicit="${2:-}" out rc=0 session
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
  session="${root}/core/scripts/hq-session.sh"
  [ -f "$session" ] || { printf ''; return 0; }
  out="$(bash "$session" get company_slugs 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || out=""
  if [ -z "$out" ] || [ "$out" = "null" ]; then
    rc=0
    out="$(bash "$session" get company_slug 2>/dev/null)" || rc=$?
    [ "$rc" -eq 0 ] || out=""
  fi
  [ "$out" = "null" ] && out=""
  printf '%s' "$out" | tr -d '[:space:]'
}

# session_lock_includes <comma-list> <slug>   (status: 0 if slug is in the list)
session_lock_includes() {
  case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}
