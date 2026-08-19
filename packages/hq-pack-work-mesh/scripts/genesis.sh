#!/usr/bin/env bash
# Push an HQ project onto the live work mesh and ensure its channel.
#
#   bash genesis.sh [--company <slug|cmp_*>] <project-slug> ["summary"]
#
# Resolves companyUid from --company, WORK_MESH_COMPANY_UID, or
# companies/{slug}/company.yaml cloudCompanyUid. Never hardcodes a tenant.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-}"
if [ -z "$HQ_ROOT" ]; then
  here="$SCRIPT_DIR"
  HQ_ROOT=""
  for _ in 1 2 3 4 5 6; do
    here="$(cd "$here/.." && pwd)"
    if [ -d "$here/companies" ]; then HQ_ROOT="$here"; break; fi
  done
  [ -n "$HQ_ROOT" ] || HQ_ROOT="$(pwd)"
fi

CO_ARG=""
if [ "${1:-}" = "--company" ]; then
  CO_ARG="${2:-}"
  shift 2
fi

PROJ="${1:-}"
SUMMARY="${2:-HQ project genesis}"
[ -n "$PROJ" ] || { echo "usage: genesis.sh [--company <slug|uid>] <project-slug> [summary]" >&2; exit 2; }

API="${HQ_PRO_API:-${HQ_WORK_MESH_API_URL:-https://hqapi.getindigo.ai}}"
TOKENS="${HQ_COGNITO_TOKENS:-$HOME/.hq/cognito-tokens.json}"
[ -f "$TOKENS" ] || { echo "genesis: no Cognito token at $TOKENS" >&2; exit 1; }

resolve_company_uid() {
  local raw="${1:-${WORK_MESH_COMPANY_UID:-}}"
  if [ -z "$raw" ]; then
    echo "genesis: pass --company <slug|cmp_*> or set WORK_MESH_COMPANY_UID" >&2
    return 1
  fi
  if [[ "$raw" == cmp_* ]]; then
    printf '%s' "$raw"
    return 0
  fi
  local yaml="$HQ_ROOT/companies/$raw/company.yaml"
  [ -f "$yaml" ] || { echo "genesis: no $yaml" >&2; return 1; }
  python3 - "$yaml" <<'PY'
import sys
path = sys.argv[1]
uid = ""
with open(path) as f:
    for line in f:
        if line.lstrip().startswith("cloudCompanyUid:"):
            uid = line.split(":", 1)[1].strip().strip("'\"")
            break
if not uid.startswith("cmp_"):
    raise SystemExit("genesis: companies/*/company.yaml missing cloudCompanyUid")
print(uid)
PY
}

CO="$(resolve_company_uid "$CO_ARG")"
export WORK_MESH_COMPANY_UID="$CO"

token() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('idToken') or '')" "$TOKENS"; }

api() {
  local method="$1" path="$2" body="${3:-}"
  local tok; tok="$(token)"
  [ -n "$tok" ] || { echo "genesis: empty idToken" >&2; exit 1; }
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "$API$path" \
      -H "Authorization: Bearer $tok" -H "Content-Type: application/json" --data "$body"
  else
    curl -fsS -X "$method" "$API$path" -H "Authorization: Bearer $tok"
  fi
}

HELPER=""
for cand in "$SCRIPT_DIR/hq-work-mesh.sh" "$SCRIPT_DIR/work-mesh.sh" \
            "${HOME:-}/.hq/work-mesh/bin/work-mesh.sh"; do
  if [ -x "$cand" ]; then HELPER="$cand"; break; fi
done
if [ -n "$HELPER" ]; then
  echo "genesis: mesh start $PROJ"
  bash "$HELPER" start --company "$CO" --project "$PROJ" --summary "$SUMMARY" --silent >/dev/null || \
    bash "$HELPER" start --company "$CO" --project "$PROJ" --summary "$SUMMARY"
fi

echo "genesis: ensure-project $PROJ"
ENSURE_BODY="$(python3 -c 'import json,sys; print(json.dumps({"companyUid":sys.argv[1],"projectId":sys.argv[2]}))' "$CO" "$PROJ")"
ENSURE="$(api POST "/v1/notify/channels/ensure-project" "$ENSURE_BODY")"
echo "$ENSURE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ch = d.get("channel") or {}
cid = ch.get("channelId")
pid = ch.get("projectId")
if not cid or pid != sys.argv[1]:
    raise SystemExit("genesis: channel metadata incomplete: %s" % list(ch))
joined = (d.get("membership") or {}).get("joined")
print("genesis: channel ok channelId=%s projectId=%s created=%s joined=%s" % (
    cid, pid, d.get("created"), joined))
' "$PROJ"

# Sidecar next to the HQ project if the dir exists (any company slug).
REC=""
if [ -n "$CO_ARG" ] && [ -d "$HQ_ROOT/companies/$CO_ARG/projects/$PROJ" ]; then
  REC="$HQ_ROOT/companies/$CO_ARG/projects/$PROJ/fabric-genesis.json"
else
  for d in "$HQ_ROOT"/companies/*/projects/"$PROJ"; do
    if [ -d "$d" ]; then REC="$d/fabric-genesis.json"; break; fi
  done
fi
if [ -n "$REC" ]; then
  python3 - "$REC" "$PROJ" "$ENSURE" <<'PY'
import json,sys
from datetime import datetime, timezone
path, proj, ensure_raw = sys.argv[1:4]
ens=json.loads(ensure_raw)
ch=ens.get("channel") or {}
out={
  "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "projectId": proj,
  "channelId": ch.get("channelId"),
  "channelName": ch.get("name"),
  "channelCreated": ens.get("created"),
  "joined": (ens.get("membership") or {}).get("joined"),
}
with open(path,"w") as f:
    json.dump(out,f,indent=2)
    f.write("\n")
print("genesis: wrote", path)
PY
fi

PRD_PATH=""
if [ -n "$CO_ARG" ] && [ -f "$HQ_ROOT/companies/$CO_ARG/projects/$PROJ/prd.json" ]; then
  PRD_PATH="$HQ_ROOT/companies/$CO_ARG/projects/$PROJ/prd.json"
else
  for f in "$HQ_ROOT"/companies/*/projects/"$PROJ"/prd.json; do
    if [ -f "$f" ]; then PRD_PATH="$f"; break; fi
  done
fi
if [ -z "$PRD_PATH" ]; then
  echo "genesis: no local prd.json — put stub project view $PROJ" >&2
fi
echo "genesis: put project view $PROJ"
VIEW_BODY="$(python3 - "${PRD_PATH:-/dev/null}" "$CO" "$PROJ" <<'PY'
import json, sys, os
prd_path, co, proj = sys.argv[1], sys.argv[2], sys.argv[3]
prd = json.loads(open(prd_path).read()) if os.path.isfile(prd_path) else {}
meta = prd.get("metadata") or {}
stories = []
for s in prd.get("userStories") or []:
    if not isinstance(s, dict) or not s.get("id"):
        continue
    ac = []
    for item in s.get("acceptanceCriteria") or []:
        if isinstance(item, str) and item.strip():
            ac.append(item.strip())
        elif isinstance(item, dict) and str(item.get("text") or "").strip():
            ac.append(str(item["text"]).strip())
    passes = s.get("passes") is True
    status = s.get("status") if s.get("status") in ("queued", "in_progress", "review", "done") else (
        "done" if passes else "queued"
    )
    stories.append({
        "id": str(s["id"]).strip(),
        "title": (s.get("title") or "").strip(),
        "description": (s.get("description") or "").strip(),
        "acceptanceCriteria": ac,
        "status": status,
        "passes": status == "done",
        "priority": s.get("priority") if isinstance(s.get("priority"), (int, float)) else None,
    })
repos = []
for raw in (prd.get("repos") or meta.get("repos") or []):
    if not isinstance(raw, dict):
        continue
    path = (raw.get("path") or raw.get("repoPath") or raw.get("repo") or "").strip()
    if not path:
        continue
    repos.append({
        "path": path,
        "branch": (raw.get("branch") or raw.get("branchName") or "").strip(),
    })
if not repos:
    path = (meta.get("repoPath") or prd.get("repoPath") or "").strip()
    if path:
        repos.append({
            "path": path,
            "branch": (prd.get("branchName") or meta.get("branchName") or "").strip(),
        })
print(json.dumps({
    "companyUid": co,
    "name": prd.get("name") or proj,
    "description": prd.get("description") or "",
    "stories": stories,
    "repos": repos,
}))
PY
)"
VIEW="$(api PUT "/v1/work-mesh/projects/$PROJ" "$VIEW_BODY")"
printf '%s' "$VIEW" | python3 -c '
import json,sys
from pathlib import Path
d=json.loads(sys.stdin.read())
co=(d.get("companyUid") or "").strip()
pid=(d.get("projectId") or "").strip()
ok=co and pid and all(c.isalnum() or c in "._-" for c in co+pid) and ".." not in co and ".." not in pid
if ok:
    dest=Path.home()/".hq/work-mesh/cache/projects"/co/f"{pid}.json"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(d, indent=2)+"\n")
' || true
echo "$VIEW" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("projectId") != sys.argv[1]:
    raise SystemExit("genesis: project view missing projectId: %s" % list(d))
print("genesis: view ok projectId=%s stories=%s repos=%s" % (
    d.get("projectId"), len(d.get("stories") or []), len(d.get("repos") or [])))
' "$PROJ"
