#!/usr/bin/env bash
# Regression: gstack-bridge must resolve the actual HQ root when run directly
# or through the installed core/scripts symlink. It must also materialize a
# namespaced SKILL.md instead of exposing upstream bare frontmatter names.
set -euo pipefail

PACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$PACK/scripts/gstack-bridge.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/gstack-bridge-test.XXXXXX")"

cleanup() {
  rm -rf "$FIXTURE"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_skill() {
  local path="$1" name="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '---' "name: $name" '---' '# test skill' > "$path"
}

assert_namespaced_copy() {
  local target="$FIXTURE/.claude/skills/g-learn"
  [[ -d "$target" ]] || fail "g-learn was not installed"
  [[ ! -L "$target" ]] || fail "g-learn must be a materialized directory, not a symlink"
  grep -qx 'name: g-learn' "$target/SKILL.md" || fail "g-learn frontmatter was not namespaced"
  grep -qx 'name: learn' "$FIXTURE/repos/public/gstack/learn/SKILL.md" \
    || fail "source gstack skill was modified"
  [[ -f "$target/.hq-gstack-bridge-source" ]] \
    || fail "materialized bridge skill is missing its ownership marker"
}

mkdir -p \
  "$FIXTURE/core/packages/hq-pack-gstack/scripts" \
  "$FIXTURE/core/scripts" \
  "$FIXTURE/source-tree/scripts" \
  "$FIXTURE/.claude/skills" \
  "$FIXTURE/repos/public/gstack/learn"
printf '%s\n' 'version: test' > "$FIXTURE/core/core.yaml"
write_skill "$FIXTURE/repos/public/gstack/learn/SKILL.md" learn
cp "$BRIDGE" "$FIXTURE/core/packages/hq-pack-gstack/scripts/gstack-bridge.sh"
cp "$BRIDGE" "$FIXTURE/source-tree/scripts/gstack-bridge.sh"
ln -s ../packages/hq-pack-gstack/scripts/gstack-bridge.sh "$FIXTURE/core/scripts/gstack-bridge.sh"

# A source-tree invocation can opt into its host instance explicitly.
HQ_ROOT="$FIXTURE" bash "$FIXTURE/source-tree/scripts/gstack-bridge.sh" install
assert_namespaced_copy
HQ_ROOT="$FIXTURE" bash "$FIXTURE/source-tree/scripts/gstack-bridge.sh" remove
[[ ! -e "$FIXTURE/.claude/skills/g-learn" ]] || fail "source-tree remove did not remove g-learn"

# Direct physical-script execution must locate the fixture HQ root by marker.
bash "$FIXTURE/core/packages/hq-pack-gstack/scripts/gstack-bridge.sh" install
assert_namespaced_copy
bash "$FIXTURE/core/packages/hq-pack-gstack/scripts/gstack-bridge.sh" remove
[[ ! -e "$FIXTURE/.claude/skills/g-learn" ]] || fail "direct remove did not remove g-learn"

# scan-packages installs the bridge under core/scripts as a symlink.
bash "$FIXTURE/core/scripts/gstack-bridge.sh" install
assert_namespaced_copy
bash "$FIXTURE/core/scripts/gstack-bridge.sh" remove
[[ ! -e "$FIXTURE/.claude/skills/g-learn" ]] || fail "symlink remove did not remove g-learn"

# A different existing skill cannot register the bridged g-prefixed name.
write_skill "$FIXTURE/.claude/skills/existing/SKILL.md" g-learn
if bash "$FIXTURE/core/scripts/gstack-bridge.sh" install > "$FIXTURE/conflict.log" 2>&1; then
  fail "bridge installed despite an existing g-learn skill name"
fi
grep -q 'registered skill name' "$FIXTURE/conflict.log" \
  || fail "bridge did not explain the registered-name conflict"
[[ ! -e "$FIXTURE/.claude/skills/g-learn" ]] \
  || fail "bridge changed targets before rejecting the registered-name conflict"

echo "gstack-bridge: ok (source tree, direct root, installed symlink, namespaced frontmatter, collision guard)"
