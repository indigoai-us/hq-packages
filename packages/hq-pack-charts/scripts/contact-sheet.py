#!/usr/bin/env python3
"""Extract every chart from one or more HTML files into a single contact sheet.

    python3 scripts/contact-sheet.py report.html
    python3 scripts/contact-sheet.py report.html --cols 2 --open
    python3 scripts/contact-sheet.py assets/examples/*.html -o /tmp/sheet.html

Why this exists: the linter proves nothing mechanical is wrong. It cannot see a
legend line drawn through a decision diamond, a label sitting on a ring, or two
node treatments that turned out identical. Those need eyes.

Scrolling a long report and screenshotting each figure is expensive enough that
it gets skipped — which is exactly how a gallery shipped with a legend cutting
through a flowchart. One command, one page, every figure at once, is cheap
enough to actually do.

Fewer columns = larger figures. Use --cols 2 when checking label legibility,
--cols 3 or 4 for a structural sweep.

Standard library only.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CSS_PATH = ROOT / "assets" / "chart.css"

SVG_RE = re.compile(r'(<svg\b[^>]*class="[^"]*\bch\b[^"]*"[^>]*>.*?</svg>)', re.S)
TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.S)
VB_RE = re.compile(r'viewBox="([^"]*)"')


def extract(paths: list[Path]) -> list[tuple[str, str, str]]:
    """Return (label, viewBox, svg-markup) for every ch figure found."""
    found = []
    for path in paths:
        if not path.exists():
            print(f"warning: {path} not found", file=sys.stderr)
            continue
        text = path.read_text(encoding="utf-8")
        # Strip <style> and <script> bodies first. chart.css documents its own
        # density modifier as `<svg class="ch ch--comfortable|ch--compact">` in a
        # CSS comment, and matching that swallows the stylesheet plus every
        # element up to the first real </svg>. Then strip HTML comments, so a
        # template's commented-out example markup is not mistaken for a figure.
        text = re.sub(r"<style\b.*?</style>", "", text, flags=re.S | re.I)
        text = re.sub(r"<script\b.*?</script>", "", text, flags=re.S | re.I)
        text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
        svgs = SVG_RE.findall(text)
        for i, svg in enumerate(svgs):
            title = TITLE_RE.search(svg)
            label = " ".join(title.group(1).split()) if title else f"{path.stem} #{i+1}"
            vb = VB_RE.search(svg)
            found.append((label, vb.group(1) if vb else "(no viewBox)", svg))
    return found


def render(figures: list[tuple[str, str, str]], cols: int, out: Path,
           theme: str, offset: int = 0) -> None:
    css = CSS_PATH.read_text(encoding="utf-8") if CSS_PATH.exists() else ""
    cells = "\n".join(
        f'<figure class="cell"><figcaption>'
        f'<span class="n">{i+1+offset:02d}</span>{label}'
        f'<span class="vb">{vb}</span></figcaption>{svg}</figure>'
        for i, (label, vb, svg) in enumerate(figures)
    )
    out.write_text(f"""<!DOCTYPE html>
<html lang="en" data-ch-theme="{theme}">
<head><meta charset="utf-8"><title>contact sheet — {len(figures)} figures</title>
<style>
{css}
body {{ margin: 0; padding: 12px; background: var(--ch-paper); }}
.grid {{ display: grid; grid-template-columns: repeat({cols}, minmax(0,1fr)); gap: 12px; }}
.cell {{ margin: 0; padding: 8px; background: var(--ch-paper);
         border: 1px solid var(--ch-rule); border-radius: 6px; }}
.cell figcaption {{ display: flex; gap: 8px; align-items: baseline; margin-bottom: 6px;
   font-family: var(--ch-font-mono); font-size: 10px; letter-spacing: 0.1em;
   text-transform: uppercase; color: var(--ch-muted); }}
.cell .n {{ color: var(--ch-soft); }}
.cell .vb {{ margin-left: auto; color: var(--ch-soft); text-transform: none;
             letter-spacing: 0; }}
.cell svg {{ display: block; width: 100%; height: auto; }}
</style></head>
<body><div class="grid">
{cells}
</div></body></html>
""", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", type=Path)
    ap.add_argument("--cols", type=int, default=3, help="grid columns (default 3)")
    ap.add_argument("-o", "--out", type=Path, default=Path("/tmp/ch-contact-sheet.html"))
    ap.add_argument("--theme", choices=("light", "dark"), default="light")
    ap.add_argument("--slice", metavar="A:B",
                    help="only figures A..B, 1-indexed inclusive (e.g. 10:15). "
                         "Screenshot tools often capture the top of the page and "
                         "ignore scripted scrolling, so slicing is how you get at "
                         "figures further down without fighting the viewport.")
    ap.add_argument("--open", action="store_true", help="open it when done (macOS)")
    args = ap.parse_args()

    figures = extract(args.files)
    if not figures:
        print("no ch figures found", file=sys.stderr)
        return 1

    offset = 0
    if args.slice:
        try:
            a, b = (int(v) for v in args.slice.split(":"))
        except ValueError:
            print("--slice wants A:B, 1-indexed", file=sys.stderr)
            return 1
        offset = max(0, a - 1)
        figures = figures[offset:b]
        if not figures:
            print(f"--slice {args.slice} selected nothing", file=sys.stderr)
            return 1

    render(figures, args.cols, args.out, args.theme, offset)
    print(f"{len(figures)} figure(s) → {args.out}")
    for i, (label, vb, _) in enumerate(figures):
        print(f"  {i+1+offset:02d}  {vb:<16} {label}")
    print("\nNow LOOK at it. The linter cannot see a legend line crossing a shape,\n"
          "a label sitting on a ring, or two treatments that render identically.")

    if args.open:
        subprocess.run(["open", str(args.out)], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
