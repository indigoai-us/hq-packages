#!/usr/bin/env bash
# Structural integrity for hq-pack-vyg-email-blocks (US-022).
# No network, no VYG, no typecheck. Run: bash tests/pack-shell.test.sh
set -euo pipefail

PACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

ok() { printf 'ok: %s\n' "$1"; }

test -f "$PACK/package.yaml" || fail "package.yaml missing"
test -f "$PACK/package.json" || fail "package.json missing"
test -f "$PACK/README.md" || fail "README.md missing"
test -f "$PACK/SMOKE-RUN.md" || fail "SMOKE-RUN.md missing"
test -f "$PACK/cover.jpg" || fail "cover.jpg missing (policy hq-pack-publish-requires-cover-image)"

# Cover is a JPEG (marketplace listing image).
if ! file "$PACK/cover.jpg" | grep -qi 'JPEG'; then
  fail "cover.jpg is not a JPEG ($(file "$PACK/cover.jpg"))"
else
  ok "cover.jpg is JPEG"
fi

# package.yaml ↔ package.json version parity (same invariant as tests/manifest-integrity.test.sh).
yaml_version="$(sed -n 's/^version:[[:space:]]*//p' "$PACK/package.yaml" | head -1)"
json_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$PACK/package.json")"
if [ -z "$yaml_version" ]; then
  fail "package.yaml has no version"
elif [ "$yaml_version" != "$json_version" ]; then
  fail "version mismatch package.yaml='$yaml_version' package.json='$json_version'"
else
  ok "version $yaml_version"
fi

name="$(sed -n 's/^name:[[:space:]]*//p' "$PACK/package.yaml" | head -1)"
[ "$name" = "hq-pack-vyg-email-blocks" ] || fail "package.yaml name is '$name'"

# Policy hq-pack-manifest-has-no-credentials-or-connections-contract:
# MCP endpoints and secrets live in README, not package.yaml.
if grep -E 'api\.vyg\.app|agents-mcp\.vyg\.app|client_secret|oauth|BEGIN [A-Z ]*PRIVATE KEY|sk_live|xoxp-|xoxb-' "$PACK/package.yaml" >/dev/null; then
  fail "package.yaml must not contain MCP URLs, OAuth, or credentials"
else
  ok "package.yaml has no connections contract"
fi

# README documents both MCP endpoints.
for url in 'https://api.vyg.app/mcp' 'https://agents-mcp.vyg.app/mcp'; do
  grep -F "$url" "$PACK/README.md" >/dev/null || fail "README.md missing $url"
done
ok "README documents both MCP endpoints"

# Skills required by US-022.
for skill in email-block-design email-block-preview email-block-test-send email-block-publish; do
  f="$PACK/skills/$skill/SKILL.md"
  if [ ! -f "$f" ]; then
    fail "missing $f"
    continue
  fi
  grep -q "^name: $skill" "$f" || fail "$f frontmatter name != $skill"
done
ok "four skills present"

# Knowledge required by US-022.
for doc in block-contracts.md kinetic-limits.md amp-prerequisites.md design-guide.md README.md; do
  test -f "$PACK/knowledge/vyg-email-blocks/$doc" || fail "missing knowledge/vyg-email-blocks/$doc"
done
ok "knowledge present"

# Skills must name the live MCP tools (not the stale PRD aliases).
grep -q 'email_block_contracts_list' "$PACK/skills/email-block-design/SKILL.md" || fail "design skill missing email_block_contracts_list"
grep -q 'email_template_validate' "$PACK/skills/email-block-design/SKILL.md" || fail "design skill missing email_template_validate"
grep -q 'email_template_preview_tiers' "$PACK/skills/email-block-preview/SKILL.md" || fail "preview skill missing email_template_preview_tiers"
grep -q 'email_template_test_send_interactive' "$PACK/skills/email-block-test-send/SKILL.md" || fail "test-send skill missing email_template_test_send_interactive"
grep -q 'email_flow_create' "$PACK/skills/email-block-publish/SKILL.md" || fail "publish skill missing email_flow_create"
grep -q 'email_broadcast_create' "$PACK/skills/email-block-publish/SKILL.md" || fail "publish skill missing email_broadcast_create"
ok "skills name live MCP tools"

# Smoke-run placeholder exists and is explicit about brand-user OAuth.
grep -q 'https://api.vyg.app/mcp' "$PACK/SMOKE-RUN.md" || fail "SMOKE-RUN.md missing primary MCP URL"
grep -qi 'brand user' "$PACK/SMOKE-RUN.md" || fail "SMOKE-RUN.md must require brand-user OAuth"
grep -qi 'pending deploy' "$PACK/SMOKE-RUN.md" || fail "SMOKE-RUN.md must mark the log as pending deploy"
ok "SMOKE-RUN.md placeholder"

# package.yaml contributes the four skills + knowledge slug.
grep -q 'email-block-design' "$PACK/package.yaml" || fail "package.yaml missing email-block-design"
grep -q 'vyg-email-blocks' "$PACK/package.yaml" || fail "package.yaml missing knowledge slug"

if [ "$failures" -ne 0 ]; then
  printf '\npack-shell FAILED (%s problem(s))\n' "$failures" >&2
  exit 1
fi
echo "pack-shell.test: ok"
