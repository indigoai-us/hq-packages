#!/usr/bin/env bash
# Test stand-in for .claude/skills/deploy/scripts/deploy-api-request.sh, used
# when the real /deploy skill is not available (CI outside an HQ tree). Same
# arguments and output contract: body on stdout on 2xx, one "[deploy] stage=..
# status=.. api_code=.." line on stderr and exit 1 otherwise. No jq needed.
set -uo pipefail
STAGE="" METHOD="" URL="" DATA="" EXPECT=""
HEADERS=() FORMS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2 ;;
    --method) METHOD="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --org|--scope) shift 2 ;;
    --header) HEADERS+=(-H "$2"); shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    --form-string) FORMS+=(--form-string "$2"); shift 2 ;;
    --form-file) FORMS+=(--form "${2%%=*}=@${2#*=};type=application/gzip;filename=upload.tar.gz"); shift 2 ;;
    --expect) EXPECT="$2"; shift 2 ;;
    *) echo "usage" >&2; exit 64 ;;
  esac
done
[ -n "${HQ_DEPLOY_JWT:-}" ] || { echo "[deploy] stage=$STAGE request not sent: missing deploy identity" >&2; exit 1; }
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
args=(-sS -o "$body" -w '%{http_code}' -X "$METHOD" -H "Authorization: Bearer $HQ_DEPLOY_JWT" "${HEADERS[@]}")
[ -n "$DATA" ] && args+=(--data "$DATA")
[ ${#FORMS[@]} -gt 0 ] && args+=("${FORMS[@]}")
status="$(curl "${args[@]}" "$URL")" || { echo "[deploy] stage=$STAGE status=000 api_code=TRANSPORT_ERROR" >&2; exit 1; }
case "$status" in
  2*) cat "$body" ;;
  *)
    code="$(node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log((o.error&&o.error.code)||o.code||"HTTP_ERROR")}catch{console.log("HTTP_ERROR")}' "$body")"
    echo "[deploy] stage=$STAGE method=$METHOD status=$status api_code=$code" >&2
    exit 1
    ;;
esac
