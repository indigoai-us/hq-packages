#!/usr/bin/env bash
# hq-slack — MCP-free Slack CLI for post/read/reply/search, acting AS you.
#
# Why this exists: this is the canonical, MCP-free path for owner-level Slack
# messaging. Slack's Web API is plain HTTPS, so a token + curl handles
# post/read/reply/search. This wrapper sources the per-workspace USER token
# (xoxp-, acts as you) from the HQ vault (preferred) or a local ~/.mcp.json
# (legacy fallback) — the token is NEVER printed or passed on the command line.
#
# First-time setup (create your own Slack app + mint a user token):
#   see knowledge/hq-slack/create-your-slack-app.md in this pack.
#
# Usage:
#   hq-slack whoami [workspace]
#   hq-slack post   <#channel|id> <text...>            [--ws <name>]
#   hq-slack read   <#channel|id> [count=20]            [--ws <name>]
#   hq-slack thread <#channel|id> <thread_ts> [count]   [--ws <name>]
#   hq-slack reply  <#channel|id> <thread_ts> <text...> [--ws <name>]
#   hq-slack search <query...>                          [--ws <name>]
#   hq-slack dm     <email|@user|U-id> <text...>        [--ws <name>]
#   hq-slack upload <#channel|id> <file> [comment...]   [--ws <name>]
#   hq-slack channels [name-prefix]                     [--ws <name>]
#
# Workspace defaults to "default" (token key SLACK_TOKEN_DEFAULT_USER). Use
# --ws <name> (or env HQ_SLACK_WS) to switch — the key becomes
# SLACK_TOKEN_<NAME>_USER. Channel names (#hq-dev or hq-dev) resolve to IDs
# automatically.
#
# Examples:
#   hq-slack post '#general' 'shipping 0.1.0 now'
#   hq-slack read '#general' 10
#   hq-slack reply '#general' 1779508819.862159 'follow-up: ships tomorrow'
set -euo pipefail

WS="${HQ_SLACK_WS:-default}"

# Locate .mcp.json (legacy token store). Override with HQ_SLACK_MCP_JSON;
# otherwise try the HQ root then the home dir. This is now an OPTIONAL fallback —
# the preferred Slack-token source is the HQ vault (hq secrets). A missing
# .mcp.json is fine for vault-provisioned setups.
MCP_JSON=""
for cand in "${HQ_SLACK_MCP_JSON:-}" "${HOME}/Documents/HQ/.mcp.json" "${HOME}/.mcp.json" "$(pwd)/.mcp.json"; do
  [ -n "$cand" ] && [ -f "$cand" ] && { MCP_JSON="$cand"; break; }
done

# --ws <name> / --thread <ts> may appear anywhere; strip them out of positional args.
THREAD="${HQ_SLACK_THREAD:-}"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ws) WS="$2"; shift 2 ;;
    --thread) THREAD="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
# Guard the empty-array case (macOS bash 3.2 + `set -u` treats "${ARGS[@]}" as
# unbound when ARGS is empty, e.g. bare `hq-slack` with no subcommand).
if [ ${#ARGS[@]} -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

token() {
  # Resolve the Slack USER token (xoxp) for $WS. The value is captured by the
  # caller and passed via header/env — never echoed to the terminal.
  #   1) Legacy local fast-path: SLACK_TOKEN_<WS>_USER|_BOT in .mcp.json.
  #   2) Preferred / recommended: the HQ vault via hq-secrets (personal scope),
  #      key SLACK_TOKEN_<WS>_USER (e.g. SLACK_TOKEN_DEFAULT_USER). Store with
  #      `hq secrets --personal set SLACK_TOKEN_<WS>_USER --from-stdin`.
  local out=""
  if [ -n "$MCP_JSON" ] && [ -f "$MCP_JSON" ]; then
    out="$(python3 - "$MCP_JSON" "$WS" <<'PY'
import json, sys
mcp, ws = sys.argv[1], sys.argv[2].upper().replace("-", "_")
try:
    d = json.load(open(mcp))
except Exception:
    sys.exit(0)
srv = d.get("mcpServers", d.get("servers", {}))
for _, c in srv.items():
    env = c.get("env", {}) if isinstance(c, dict) else {}
    tok = env.get(f"SLACK_TOKEN_{ws}_USER") or env.get(f"SLACK_TOKEN_{ws}_BOT")
    if tok:
        sys.stdout.write(tok); break
PY
)"
  fi
  if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  # Vault fallback (preferred for new setups). `get --reveal` prints a metadata
  # block; we extract just the `Value:` line. Captured here, never shown.
  local ws_uc; ws_uc="$(printf '%s' "$WS" | tr 'a-z-' 'A-Z_')"
  for key in "SLACK_TOKEN_${ws_uc}_USER" "SLACK_TOKEN_${ws_uc}_BOT"; do
    out="$(hq secrets --personal get --reveal "$key" 2>/dev/null \
           | sed -n 's/^[[:space:]]*Value:[[:space:]]*//p' | head -1)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  done
  {
    echo "hq-slack: no Slack token for workspace '$WS'."
    echo "Create your own Slack app + mint a user token: see"
    echo "  knowledge/hq-slack/create-your-slack-app.md (in this pack)."
    echo "Then store it in the HQ vault:"
    echo "  printf '%s' '<xoxp-token>' | hq secrets --personal set SLACK_TOKEN_${ws_uc}_USER --from-stdin"
  } >&2
  return 1
}

api() { # api <method> <json-payload>  (POST) — token via header, never in argv
  local method="$1" payload="$2"
  TOKEN="$(token)" python3 - "$method" "$payload" <<'PY'
import os, sys, json, urllib.request
method, payload = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"https://slack.com/api/{method}",
    data=payload.encode(),
    headers={"Authorization": f"Bearer {os.environ['TOKEN']}",
             "Content-Type": "application/json; charset=utf-8"})
print(json.dumps(json.load(urllib.request.urlopen(req))))
PY
}

api_get() { # api_get <method> <querystring>
  local method="$1" qs="$2"
  TOKEN="$(token)" python3 - "$method" "$qs" <<'PY'
import os, sys, json, urllib.request
method, qs = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"https://slack.com/api/{method}?{qs}",
    headers={"Authorization": f"Bearer {os.environ['TOKEN']}"})
print(json.dumps(json.load(urllib.request.urlopen(req))))
PY
}

resolve_channel() { # #name|name|id -> id
  local c="${1#\#}"
  case "$c" in
    C0*|G0*|C[0-9A-Z]*|U[0-9A-Z]*|D[0-9A-Z]*) printf '%s' "$c"; return ;;  # already an ID (channel/user/DM)
  esac
  api_get conversations.list \
    "types=public_channel,private_channel&limit=1000&exclude_archived=true" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((x['id'] for x in d.get('channels',[]) if x.get('name')=='$c'),''))"
}

jq_field() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1'))"; }

# --- Brevity guard (recommended) -------------------------------------------
# Slack posts read best SHORT: lead with the outcome, link out for detail. The
# guard prevents a wall of text pasted into a channel — the real gate is total
# character count.
#   Tunables: HQ_SLACK_MAX_CHARS (default 600). HQ_SLACK_MAX_LINES is OFF by
#   default; set it to a number to add a line gate. Escape hatch for a
#   genuinely-sanctioned long post: HQ_SLACK_ALLOW_LONG=1.
HQ_SLACK_MAX_CHARS="${HQ_SLACK_MAX_CHARS:-600}"
HQ_SLACK_MAX_LINES="${HQ_SLACK_MAX_LINES:-}"   # empty = no line gate
enforce_brevity() {
  [ "${HQ_SLACK_ALLOW_LONG:-0}" = "1" ] && return 0
  local text="$1" chars lines
  chars=$(printf '%s' "$text" | wc -m | tr -d ' ')
  if [ "$chars" -gt "$HQ_SLACK_MAX_CHARS" ]; then
    {
      echo "hq-slack: message too long for Slack (${chars} chars; limit ${HQ_SLACK_MAX_CHARS})."
      echo "Keep it scannable — lead with the outcome, use line breaks + a few bullets, link out for the rest."
      echo "For a genuinely long, sanctioned post: re-run with HQ_SLACK_ALLOW_LONG=1."
    } >&2
    return 1
  fi
  if [ -n "$HQ_SLACK_MAX_LINES" ]; then
    lines=$(printf '%s\n' "$text" | grep -c '')
    if [ "$lines" -gt "$HQ_SLACK_MAX_LINES" ]; then
      echo "hq-slack: message has ${lines} lines (limit ${HQ_SLACK_MAX_LINES}); re-run with HQ_SLACK_ALLOW_LONG=1 to override." >&2
      return 1
    fi
  fi
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  whoami)
    api_get auth.test "" | python3 -c "import sys,json;d=json.load(sys.stdin);print('ws=$WS', {k:d.get(k) for k in ['ok','team','user','user_id','error']})"
    ;;
  post)
    ch="$(resolve_channel "$1")"; shift; text="$*"
    [ -n "$ch" ] || { echo "channel not found" >&2; exit 1; }
    enforce_brevity "$text" || exit 2
    api chat.postMessage "$(THREAD="$THREAD" python3 -c "import json,sys,os
p=dict(channel=sys.argv[1],text=sys.argv[2],unfurl_links=False)
if os.environ.get('THREAD'): p['thread_ts']=os.environ['THREAD']
print(json.dumps(p))" "$ch" "$text")" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print('posted' if d.get('ok') else 'ERROR', {k:d.get(k) for k in ['ok','ts','channel','error']})"
    ;;
  thread)
    # thread <#channel|id> <thread_ts> [count=50] — read replies in a thread.
    ch="$(resolve_channel "$1")"; troot="$2"; n="${3:-50}"
    [ -n "$ch" ] || { echo "channel not found" >&2; exit 1; }
    api_get conversations.replies "channel=$ch&ts=$troot&limit=$n" \
      | python3 -c "
import sys,json
d=json.load(sys.stdin)
if not d.get('ok'): print('ERROR',d.get('error')); sys.exit(1)
for m in d.get('messages',[]):
    print(f\"[{m.get('ts')}] {m.get('user','?')}: {m.get('text','').replace(chr(10),' ')[:400]}\")
"
    ;;
  read)
    ch="$(resolve_channel "$1")"; n="${2:-20}"
    [ -n "$ch" ] || { echo "channel not found" >&2; exit 1; }
    api_get conversations.history "channel=$ch&limit=$n" \
      | python3 -c "
import sys,json
d=json.load(sys.stdin)
if not d.get('ok'): print('ERROR',d.get('error')); sys.exit(1)
for m in reversed(d.get('messages',[])):
    print(f\"[{m.get('ts')}] {m.get('user','?')}: {m.get('text','').replace(chr(10),' ')[:300]}\")
"
    ;;
  reply)
    ch="$(resolve_channel "$1")"; thread="$2"; shift 2; text="$*"
    [ -n "$ch" ] || { echo "channel not found" >&2; exit 1; }
    enforce_brevity "$text" || exit 2
    api chat.postMessage "$(python3 -c "import json,sys;print(json.dumps(dict(channel=sys.argv[1],thread_ts=sys.argv[2],text=sys.argv[3],unfurl_links=False)))" "$ch" "$thread" "$text")" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print('replied' if d.get('ok') else 'ERROR', {k:d.get(k) for k in ['ok','ts','error']})"
    ;;
  dm)
    # dm <email|@user|U-id> <text...> — resolve to a user ID, then post.
    # chat.postMessage opens/uses the IM when channel is a user ID.
    target="$1"; shift; text="$*"
    uid=""
    case "$target" in
      U[0-9A-Z]*|D[0-9A-Z]*) uid="$target" ;;
      *@*) # email -> user id (needs users:read.email on the token)
        uid="$(api_get users.lookupByEmail "email=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$target")" \
          | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('user',{}).get('id','') if d.get('ok') else '')")" ;;
      *) # @handle or handle -> scan users.list display/real names
        h="${target#@}"
        uid="$(api_get users.list "limit=1000" \
          | python3 -c "import sys,json;h='$h'.lower();d=json.load(sys.stdin);
print(next((u['id'] for u in d.get('members',[]) if not u.get('deleted') and h in (u.get('name','').lower(), (u.get('profile',{}).get('display_name','') or '').lower(), (u.get('profile',{}).get('real_name','') or '').lower())), ''))" )" ;;
    esac
    [ -n "$uid" ] || { echo "dm: could not resolve '$target' to a user id (token may need users:read.email / users:read)" >&2; exit 1; }
    enforce_brevity "$text" || exit 2
    api chat.postMessage "$(python3 -c "import json,sys;print(json.dumps(dict(channel=sys.argv[1],text=sys.argv[2],unfurl_links=False)))" "$uid" "$text")" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print('dm-sent' if d.get('ok') else 'ERROR', {k:d.get(k) for k in ['ok','ts','channel','error']})"
    ;;
  upload)
    # upload <#channel|id> <file-path> [initial-comment...] — share a file/image
    # to a channel via Slack's external-upload flow. Token stays in the header
    # (never printed), same as every other command here.
    ch="$(resolve_channel "$1")"; file="$2"; shift 2 || true; comment="$*"
    [ -n "$ch" ] || { echo "channel not found" >&2; exit 1; }
    [ -f "$file" ] || { echo "file not found: $file" >&2; exit 1; }
    TOKEN="$(token)" CH="$ch" FILE="$file" COMMENT="$comment" THREAD="$THREAD" python3 <<'PY'
import os, sys, json, uuid, mimetypes, urllib.parse, urllib.request
tok=os.environ["TOKEN"]; ch=os.environ["CH"]; path=os.environ["FILE"]; comment=os.environ.get("COMMENT","")
data=open(path,"rb").read(); fn=os.path.basename(path)
# 1) reserve an upload URL
body=urllib.parse.urlencode({"filename":fn,"length":len(data)}).encode()
req=urllib.request.Request("https://slack.com/api/files.getUploadURLExternal", data=body,
    headers={"Authorization":f"Bearer {tok}","Content-Type":"application/x-www-form-urlencoded"})
r=json.load(urllib.request.urlopen(req))
if not r.get("ok"): print("ERROR", {"step":"getUploadURLExternal","error":r.get("error")}); sys.exit(1)
upload_url=r["upload_url"]; file_id=r["file_id"]
# 2) PUT/POST the bytes to the reserved URL (multipart)
boundary="----hqslack"+uuid.uuid4().hex
ctype=mimetypes.guess_type(fn)[0] or "application/octet-stream"
pre=(f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{fn}\"\r\nContent-Type: {ctype}\r\n\r\n").encode()
mp=pre+data+(f"\r\n--{boundary}--\r\n").encode()
urllib.request.urlopen(urllib.request.Request(upload_url, data=mp,
    headers={"Content-Type":f"multipart/form-data; boundary={boundary}"})).read()
# 3) complete + share to the channel, with optional initial comment
comp={"files":[{"id":file_id,"title":fn}],"channel_id":ch}
if comment: comp["initial_comment"]=comment
if os.environ.get("THREAD"): comp["thread_ts"]=os.environ["THREAD"]
req3=urllib.request.Request("https://slack.com/api/files.completeUploadExternal",
    data=json.dumps(comp).encode(),
    headers={"Authorization":f"Bearer {tok}","Content-Type":"application/json; charset=utf-8"})
r3=json.load(urllib.request.urlopen(req3))
print("uploaded" if r3.get("ok") else "ERROR", {k:r3.get(k) for k in ["ok","error"]})
PY
    ;;
  search)
    q="$*"
    api_get search.messages "query=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$q")&count=20" \
      | python3 -c "
import sys,json
d=json.load(sys.stdin)
if not d.get('ok'): print('ERROR',d.get('error'),'(user token needs search:read)'); sys.exit(1)
for m in d.get('messages',{}).get('matches',[]):
    print(f\"[{m.get('ts')}] #{m.get('channel',{}).get('name','?')} {m.get('username','?')}: {m.get('text','')[:200]}\")
"
    ;;
  channels)
    # channels [name-prefix] — list channels the AUTHED USER is a member of
    # (public + private), paginating users.conversations. Prints "id\tname" per
    # line. Optional first arg filters to names starting with that prefix.
    prefix="${1:-}"
    TOKEN="$(token)" PREFIX="$prefix" python3 <<'PY'
import os, json, urllib.request, urllib.parse
tok=os.environ["TOKEN"]; prefix=os.environ.get("PREFIX","")
cursor=""; rows=[]
while True:
    qs=urllib.parse.urlencode({
        "types":"public_channel,private_channel",
        "exclude_archived":"true","limit":"1000","cursor":cursor})
    req=urllib.request.Request(f"https://slack.com/api/users.conversations?{qs}",
        headers={"Authorization":f"Bearer {tok}"})
    d=json.load(urllib.request.urlopen(req))
    if not d.get("ok"):
        print("ERROR", d.get("error"), "(token needs channels:read,groups:read)"); raise SystemExit(1)
    for c in d.get("channels",[]):
        name=c.get("name","")
        if not prefix or name.startswith(prefix):
            rows.append((c.get("id",""), name))
    cursor=d.get("response_metadata",{}).get("next_cursor","") or ""
    if not cursor: break
for cid,name in sorted(rows, key=lambda r:r[1]):
    print(f"{cid}\t{name}")
PY
    ;;
  *)
    grep -E '^#( |   )' "$0" | sed 's/^# \{0,1\}//' | head -30
    ;;
esac
