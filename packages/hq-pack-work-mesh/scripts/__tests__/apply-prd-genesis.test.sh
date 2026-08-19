#!/usr/bin/env bash
# apply.sh must insert /prd Step 5.6b and stay idempotent.
set -euo pipefail
PACK="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HQ_WORK_MESH_SKIP_MQTT=1
mkdir -p "$HOME"

HQ="$TMP/hq"
mkdir -p "$HQ/.agents/skills/prd" "$HQ/.claude/skills/prd" "$HQ/personal/skills/prd"

cat > "$HQ/.agents/skills/prd/SKILL.md" <<'MD'
# PRD

## Step 5.6: Sync to Company Board

board upsert here

## Step 6: Register with Orchestrator

orchestrator here
MD
# Hardlink the Claude copy the way this HQ tree does.
ln "$HQ/.agents/skills/prd/SKILL.md" "$HQ/.claude/skills/prd/SKILL.md"
cp "$HQ/.agents/skills/prd/SKILL.md" "$HQ/personal/skills/prd/SKILL.md"

# Isolated apply: skip scan-packages (no core/scripts) and still patch PRD.
bash "$PACK/scripts/lib/install-isolated-bin.sh" >/dev/null
bash "$PACK/scripts/lib/patch-prd-genesis.sh" "$HQ"

grep -q "Step 5.6b: Work-mesh genesis" "$HQ/.agents/skills/prd/SKILL.md"
grep -q "hq-work-mesh-genesis.sh --company {co} {name}" "$HQ/.agents/skills/prd/SKILL.md"
grep -q "Step 5.6b: Work-mesh genesis" "$HQ/.claude/skills/prd/SKILL.md"
grep -q "Step 5.6b: Work-mesh genesis" "$HQ/personal/skills/prd/SKILL.md"
# Inserted once, before Step 6.
test "$(grep -c 'Step 5.6b: Work-mesh genesis' "$HQ/.agents/skills/prd/SKILL.md")" = 1
grep -q "Step 6: Register with Orchestrator" "$HQ/.agents/skills/prd/SKILL.md"

# Idempotent
bash "$PACK/scripts/lib/patch-prd-genesis.sh" "$HQ" | grep -q "already present"
test "$(grep -c 'Step 5.6b: Work-mesh genesis' "$HQ/.agents/skills/prd/SKILL.md")" = 1

# Missing Step 6 is a hard fail (do not silently append).
mkdir -p "$TMP/bad/.agents/skills/prd"
echo "# no steps" > "$TMP/bad/.agents/skills/prd/SKILL.md"
if bash "$PACK/scripts/lib/patch-prd-genesis.sh" "$TMP/bad"; then
  echo "apply-prd-genesis.test: expected fail on missing Step 6" >&2
  exit 1
fi

echo "apply-prd-genesis.test: ok"
