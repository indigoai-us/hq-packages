#!/usr/bin/env bash
# Insert /prd Step 5.6b (work-mesh genesis) into local PRD skills.
# Idempotent. Does not rewrite hq-core or hq-pack-engineering copies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="${FRAGMENT:-$SCRIPT_DIR/../prd-step-5.6b.md}"
HQ_ROOT="${1:-${HQ_ROOT:-}}"
[ -n "$HQ_ROOT" ] || { echo "patch-prd-genesis: usage: $0 <hq-root>" >&2; exit 2; }
[ -f "$FRAGMENT" ] || { echo "patch-prd-genesis: missing $FRAGMENT" >&2; exit 1; }

python3 - "$HQ_ROOT" "$FRAGMENT" <<'PY'
import os
import sys
from pathlib import Path

hq = Path(sys.argv[1])
fragment = Path(sys.argv[2]).read_text()
if "Step 5.6b: Work-mesh genesis" not in fragment:
    raise SystemExit("patch-prd-genesis: fragment missing required heading")
needle = "## Step 6: Register with Orchestrator"
marker = "Step 5.6b: Work-mesh genesis"

candidates = [
    hq / ".agents/skills/prd/SKILL.md",
    hq / ".claude/skills/prd/SKILL.md",
    hq / "personal/skills/prd/SKILL.md",
]

seen_inode = set()
patched = 0
skipped = 0
missing = 0
failed = 0

for path in candidates:
    if not path.is_file():
        missing += 1
        print(f"patch-prd-genesis: skip missing {path}")
        continue
    try:
        inode = path.stat().st_ino
    except OSError:
        inode = None
    if inode is not None and inode in seen_inode:
        print(f"patch-prd-genesis: skip hardlink {path}")
        skipped += 1
        continue
    if inode is not None:
        seen_inode.add(inode)
    text = path.read_text()
    if marker in text:
        print(f"patch-prd-genesis: already present {path}")
        skipped += 1
        continue
    if needle not in text:
        print(f"patch-prd-genesis: no Step 6 heading {path}", file=sys.stderr)
        failed += 1
        continue
    insert = fragment.rstrip() + "\n\n"
    new = text.replace(needle, insert + needle, 1)
    # In-place write keeps hardlinks (.agents ↔ .claude) on the same inode.
    path.write_text(new)
    print(f"patch-prd-genesis: inserted 5.6b {path}")
    patched += 1

print(f"patch-prd-genesis: patched={patched} skipped={skipped} missing={missing} failed={failed}")
if failed:
    raise SystemExit(1)
if patched == 0 and skipped == 0:
    raise SystemExit("patch-prd-genesis: no PRD skill found under .agents, .claude, or personal")
PY
