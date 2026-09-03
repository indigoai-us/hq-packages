#!/usr/bin/env bash
# apply.sh must unload/remove legacy LaunchAgent ai.getindigo.hq-work-mesh-listen
# against a temp HOME with a fake launchctl on PATH, and must NOT install
# ~/.hq/work-mesh/bin.
set -euo pipefail
PACK="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/Library/LaunchAgents" "$TMP/bin" "$TMP/hq/.agents/skills/prd" "$TMP/hq/.claude/skills/prd" "$TMP/hq/personal/skills/prd"

LABEL="ai.getindigo.hq-work-mesh-listen"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
cat >"$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>ai.getindigo.hq-work-mesh-listen</string></dict></plist>
PLIST

# Fake launchctl records bootout/unload calls.
LAUNCHCTL_LOG="$TMP/launchctl.log"
cat >"$TMP/bin/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$LAUNCHCTL_LOG"
exit 0
EOF
chmod +x "$TMP/bin/launchctl"
export PATH="$TMP/bin:$PATH"

# Minimal PRD skill so patch-prd-genesis succeeds.
cat >"$TMP/hq/.agents/skills/prd/SKILL.md" <<'MD'
# PRD

## Step 5.6: Sync to Company Board

board upsert here

## Step 6: Register with Orchestrator

orchestrator here
MD
cp "$TMP/hq/.agents/skills/prd/SKILL.md" "$TMP/hq/.claude/skills/prd/SKILL.md"
cp "$TMP/hq/.agents/skills/prd/SKILL.md" "$TMP/hq/personal/skills/prd/SKILL.md"

export HQ_ROOT="$TMP/hq"
export HQ_WORK_MESH_SKIP_MQTT=1

out="$(bash "$PACK/scripts/apply.sh")"
echo "$out" | grep -q "removed legacy LaunchAgent $LABEL"
test ! -e "$PLIST"
grep -Eq "bootout|unload" "$LAUNCHCTL_LOG"

# Must not install the isolated listen bin.
test ! -e "$HOME/.hq/work-mesh/bin/work-mesh.mjs"
test ! -e "$HOME/.hq/work-mesh/bin/work-mesh.sh"
echo "$out" | grep -q "hq mesh daemon install"
echo "$out" | grep -q "no longer installed"

# Idempotent second apply with no plist.
out2="$(bash "$PACK/scripts/apply.sh")"
echo "$out2" | grep -q "no legacy LaunchAgent plist"

# Reject listen/watch verbs.
set +e
err="$(node "$PACK/scripts/hq-work-mesh.mjs" listen 2>&1)"
code=$?
set -e
test "$code" -eq 2
echo "$err" | grep -q "hq mesh daemon"

help="$(node "$PACK/scripts/hq-work-mesh.mjs" --help)"
echo "$help" | grep -q "hq mesh daemon"
! echo "$help" | grep -E '^  listen ' >/dev/null
! echo "$help" | grep -E '^  watch ' >/dev/null

# Version bump present.
grep -q 'version: 0.2.0' "$PACK/package.yaml"
grep -q '"version": "0.2.0"' "$PACK/package.json"
grep -q '0.2.0' "$PACK/CHANGELOG.md"
test ! -f "$PACK/scripts/install-listen.sh"
test ! -f "$PACK/hooks/SessionStart/60-work-mesh-bin.sh"

echo "apply-unload-listen.test: ok"
