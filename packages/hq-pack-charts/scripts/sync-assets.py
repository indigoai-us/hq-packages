#!/usr/bin/env python3
"""Inline assets/chart.css into every HTML file that declares the marker pair.

An HQ chart is a single self-contained file, which means the stylesheet has to
be copied into it. That copy is the thing that rots. So the copy is generated,
never hand-written, and `lint-chart.py --css` fails any file whose inlined
block has drifted.

    python3 scripts/sync-assets.py            # sync assets/, galleries/, sheets/, examples/
    python3 scripts/sync-assets.py path.html  # sync specific files
    python3 scripts/sync-assets.py --check    # exit 1 if anything is stale

Marker pair, verbatim, inside a <style> element:

    <style>/* ch:css:start */
    ...generated...
    /* ch:css:end */</style>

Standard library only. No network, no install step.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CSS_PATH = ROOT / "assets" / "chart.css"

START = "/* ch:css:start */"
END = "/* ch:css:end */"


def stylesheet() -> str:
    if not CSS_PATH.exists():
        sys.exit(f"error: stylesheet not found at {CSS_PATH}")
    return CSS_PATH.read_text(encoding="utf-8").rstrip("\n")


def fingerprint(css: str) -> str:
    return hashlib.sha256(css.encode("utf-8")).hexdigest()[:12]


def default_targets() -> list[Path]:
    targets: list[Path] = []
    for directory in (ROOT / "assets", ROOT / "assets" / "examples", ROOT / "assets" / "galleries", ROOT / "assets" / "sheets"):
        if directory.is_dir():
            targets.extend(sorted(directory.glob("*.html")))
    return targets


def rewrite(path: Path, css: str, check_only: bool) -> str:
    """Return one of: 'skipped', 'ok', 'stale', 'updated', 'malformed'."""
    text = path.read_text(encoding="utf-8")

    if START not in text:
        return "skipped"
    if END not in text:
        return "malformed"

    head, _, rest = text.partition(START)
    body, _, tail = rest.partition(END)

    banner = (
        f"\n/* GENERATED from assets/chart.css ({fingerprint(css)}) — "
        "do not edit here. Run scripts/sync-assets.py. */\n"
    )
    desired = banner + css + "\n"

    if body == desired:
        return "ok"
    if check_only:
        return "stale"

    path.write_text(head + START + desired + END + tail, encoding="utf-8")
    return "updated"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="*", type=Path)
    parser.add_argument(
        "--check",
        action="store_true",
        help="report drift without writing; exit 1 if any file is stale",
    )
    args = parser.parse_args()

    css = stylesheet()
    targets = args.files or default_targets()
    if not targets:
        print("no HTML targets found")
        return 0

    counts = {"ok": 0, "updated": 0, "stale": 0, "skipped": 0, "malformed": 0}
    problems: list[str] = []

    for path in targets:
        if not path.exists():
            problems.append(f"{path}: not found")
            counts["malformed"] += 1
            continue
        result = rewrite(path, css, args.check)
        counts[result] += 1
        rel = path.relative_to(ROOT) if ROOT in path.parents else path
        if result == "updated":
            print(f"  updated  {rel}")
        elif result == "stale":
            problems.append(f"{rel}: inlined CSS is stale")
        elif result == "malformed":
            problems.append(f"{rel}: found {START} without {END}")

    print(
        f"\n{len(targets)} file(s): {counts['ok']} current, "
        f"{counts['updated']} updated, {counts['stale']} stale, "
        f"{counts['skipped']} without markers, {counts['malformed']} malformed"
    )

    if problems:
        print("\nproblems:")
        for line in problems:
            print(f"  {line}")
        if args.check:
            print("\nrun: python3 scripts/sync-assets.py")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
