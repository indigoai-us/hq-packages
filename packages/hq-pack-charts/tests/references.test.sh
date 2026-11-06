#!/usr/bin/env bash
# Every file the /chart skill and its spec tell an agent to open must ship.
#
# Why this exists: SKILL.md and spec/04-colour.md pointed brand binding at
# core/knowledge/public/design-styles/formulas/diagram/binding.md. No pack
# ships that file, so agents had no mapping to follow (feedback 1b4acf28).
#
# Fails when:
#   a. a skill or knowledge .md, the pack README.md, or assets/chart.css names
#      a core/knowledge/ path (outside this pack, so the pack cannot guarantee
#      it exists);
#   b. a backticked pack-relative path in skills/chart/SKILL.md,
#      knowledge/charts/**/*.md or the pack README.md (spec/, types/,
#      knowledge/charts/, assets/, scripts/, skills/) does not resolve inside
#      the pack;
#   c. package.yaml recommends a pack that has no packages/<name>/package.yaml;
#   d. a line in a README.md code fence that starts with a pack path (assets/,
#      knowledge/, scripts/, skills/) names a file or directory that does not
#      ship, such as the old assets/examples/ layout line. On a line that lists
#      several names separated by "·" (scripts/a.py · b.py), each name is
#      checked, in the first path's directory unless it starts with a pack
#      path. Every {a,b,c} group is expanded, alternatives trimmed, and each
#      result checked;
#   e. spec/04-colour.md has no "## Brand binding" heading, which SKILL.md,
#      README.md, spec/01-tokens.md and chart.css all point at by name.
#
# Run locally: bash packages/hq-pack-charts/tests/references.test.sh
set -uo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$PACK_DIR/../.." && pwd)"

python3 - "$PACK_DIR" "$REPO_ROOT" <<'PY'
import re
import sys
from pathlib import Path

pack = Path(sys.argv[1])
repo = Path(sys.argv[2])
charts = pack / "knowledge" / "charts"
failures = []
checked = 0


def rel(path):
    return path.relative_to(pack).as_posix()


# a. No references into core/knowledge/ from shipped instructions.
outside = re.compile(r"core/knowledge/[^\s`'\")]*")
readme = pack / "README.md"
scan_a = sorted((pack / "skills").rglob("*.md")) + sorted((pack / "knowledge").rglob("*.md"))
scan_a += [readme, pack / "assets" / "chart.css"]
for path in scan_a:
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for match in outside.finditer(line):
            checked += 1
            failures.append(f"{rel(path)}:{lineno}: {match.group(0)} (outside this pack)")

# b. Backticked pack-relative paths resolve.
ticked = re.compile(r"`([^`\s]+)`")
prefixes = ("spec/", "types/", "knowledge/charts/", "assets/", "scripts/", "skills/")
scan_b = [pack / "skills" / "chart" / "SKILL.md"] + sorted(charts.rglob("*.md")) + [readme]
for path in scan_b:
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for match in ticked.finditer(line):
            ref = match.group(1)
            if not ref.startswith(prefixes):
                continue
            if any(ch in ref for ch in "{*<…"):
                continue
            target = ref.split("#", 1)[0].rstrip(".,;:")
            if target.startswith(("spec/", "types/")):
                candidate = charts / target
            else:
                candidate = pack / target
            checked += 1
            if not candidate.exists():
                failures.append(f"{rel(path)}:{lineno}: {ref} (not in the pack)")

# c. Recommended packs exist in this repo.
in_recommends = in_packs = False
for lineno, line in enumerate((pack / "package.yaml").read_text(encoding="utf-8").splitlines(), 1):
    if re.match(r"^\S", line):
        in_recommends = line.startswith("recommends:")
        in_packs = False
        continue
    if in_recommends and re.match(r"^\s+packs:", line):
        in_packs = True
        continue
    if in_recommends and re.match(r"^\s{2}\S", line) and not line.strip().startswith("-"):
        in_packs = False
    item = re.match(r"^\s+-\s*([A-Za-z0-9_.-]+)", line)
    if in_packs and item:
        name = item.group(1)
        checked += 1
        if not (repo / "packages" / name / "package.yaml").is_file():
            failures.append(f"package.yaml:{lineno}: {name} (recommended pack not in packages/)")

# d. Paths listed in README.md code fences (the Layout block) ship.
fence_prefixes = ("assets/", "knowledge/", "scripts/", "skills/")
brace = re.compile(r"\{([^{}]*)\}")
in_fence = False
for lineno, line in enumerate(readme.read_text(encoding="utf-8").splitlines(), 1):
    if line.lstrip().startswith("```"):
        in_fence = not in_fence
        continue
    if not in_fence:
        continue
    tokens = line.split()
    if not tokens or not tokens[0].startswith(fence_prefixes):
        continue
    first = tokens[0]
    refs = [first]
    if "·" in line:
        base = first.rsplit("/", 1)[0] + "/" if "/" in first.rstrip("/") else ""
        for part in line.split("·")[1:]:
            words = part.split()
            if not words:
                continue
            name = words[0]
            refs.append(name if name.startswith(fence_prefixes) else base + name)
    targets = []
    pending = refs
    while pending:
        ref = pending.pop(0)
        group = brace.search(ref)
        if group:
            pending.extend(
                ref[: group.start()] + alt.strip() + ref[group.end():]
                for alt in group.group(1).split(",")
            )
        else:
            targets.append(ref)
    for target in targets:
        checked += 1
        candidate = pack / target.rstrip("/")
        exists = candidate.is_dir() if target.endswith("/") else candidate.exists()
        if not exists:
            failures.append(f"README.md:{lineno}: {target} (listed in a code fence, not in the pack)")

# e. The section everything points at by name exists.
colour = charts / "spec" / "04-colour.md"
checked += 1
if not re.search(r"^## Brand binding\s*$", colour.read_text(encoding="utf-8"), re.MULTILINE):
    failures.append(f"{rel(colour)}: no '## Brand binding' heading (SKILL.md, README.md, spec/01-tokens.md and chart.css point at it)")

for failure in failures:
    print(f"FAIL: {failure}", file=sys.stderr)
if failures:
    sys.exit(1)
print(f"ok: {checked} references checked")
PY
