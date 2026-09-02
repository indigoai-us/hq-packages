#!/usr/bin/env python3
"""Regenerate the marketplace cover (cover.jpg, 1024x574) from real gallery figures.

    python3 scripts/make-cover.py            # write cover.jpg
    python3 scripts/make-cover.py --html     # write the intermediate HTML only

The cover is composed from the ACTUAL rendered output of this pack — the same
figures the galleries ship — because for a charts pack the product is the
picture. Re-run this after changing `chart.css` or any gallery card so the
listing image never drifts from what the pack actually produces.

Pipeline: extract figures from assets/galleries/*.html → compose a 2048x1148
page with the pack's own stylesheet → headless Chrome screenshot → downscale to
1024x574 JPEG (`sips` on macOS, ImageMagick elsewhere).

Standard library only, plus a headless Chrome on PATH.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CSS = ROOT / "assets" / "chart.css"
GALLERIES = ROOT / "assets" / "galleries"
OUT_JPG = ROOT / "cover.jpg"

# The four figures that carry the cover. Chosen for thumbnail legibility:
# bold bars, one ring, a row of big numbers, and a dense texture band.
PICKS = [
    ("plain.bar-ranked", "a", "Ranked"),
    ("plain.ring", "b", "Share"),
    ("signal.kpi-spark", "c", "Signal"),
    ("ledger.year-heat", "d", "A year, day by day"),
]

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome",
    "chromium",
    "chromium-browser",
]

FIGURE_RE = re.compile(r'<figure class="ch-card[^"]*" data-ch-type="([^"]+)">(.*?)</figure>', re.S)
SVG_RE = re.compile(r'(<svg class="ch".*?</svg>)', re.S)


def find_chrome() -> str | None:
    for c in CHROME_CANDIDATES:
        if Path(c).exists():
            return c
        found = shutil.which(c)
        if found:
            return found
    return None


def extract() -> dict[str, str]:
    figs: dict[str, str] = {}
    for fam in ("ledger", "plain", "signal"):
        path = GALLERIES / f"{fam}.html"
        if not path.exists():
            continue
        for m in FIGURE_RE.finditer(path.read_text(encoding="utf-8")):
            svg = SVG_RE.search(m.group(2))
            if svg:
                figs[m.group(1)] = svg.group(1)
    return figs


def namespace(svg: str, ns: str) -> str:
    """Prefix every id so four figures can share one document."""
    for i in sorted(set(re.findall(r'id="([^"]+)"', svg)), key=len, reverse=True):
        svg = svg.replace(f'id="{i}"', f'id="{ns}-{i}"').replace(f'#{i}"', f'#{ns}-{i}"')
        svg = re.sub(r'aria-labelledby="[^"]*"',
                     lambda m, i=i, ns=ns: m.group(0).replace(i, f"{ns}-{i}"), svg)
    return svg.replace('<svg class="ch"', '<svg class="ch" preserveAspectRatio="xMidYMid meet"', 1)


def compose(figs: dict[str, str]) -> str:
    missing = [k for k, _, _ in PICKS if k not in figs]
    if missing:
        sys.exit(f"make-cover: gallery figures not found: {', '.join(missing)}")
    b = {k: namespace(figs[k], ns) for k, ns, _ in PICKS}
    label = {k: lbl for k, _, lbl in PICKS}
    css = CSS.read_text(encoding="utf-8")
    return f"""<!DOCTYPE html>
<html lang="en" data-ch-theme="light" data-ch-palette="ember">
<head><meta charset="utf-8">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Geist:wght@400;500;600;700&family=Geist+Mono:wght@400;500&display=swap">
<style>
{css}
html,body{{margin:0;padding:0;background:var(--ch-paper);}}
*{{box-sizing:border-box;}}
.cover{{width:2048px;height:1148px;position:relative;overflow:hidden;background:var(--ch-paper);}}
.left{{position:absolute;left:104px;top:0;width:700px;height:1148px;
  display:flex;flex-direction:column;justify-content:center;}}
.eyebrow{{font-family:var(--ch-font-mono);font-size:25px;letter-spacing:.24em;text-transform:uppercase;
  color:var(--ch-hero);margin:0 0 34px;}}
h1{{font-family:var(--ch-font-display);font-weight:400;font-size:158px;line-height:.9;letter-spacing:-.022em;
  margin:0 0 34px;color:var(--ch-ink);}}
h1 em{{font-style:italic;color:var(--ch-hero);}}
.tag{{font-size:36px;line-height:1.32;color:var(--ch-muted);margin:0 0 46px;max-width:17ch;}}
.meta{{font-family:var(--ch-font-mono);font-size:22px;letter-spacing:.07em;color:var(--ch-soft);
  border-top:3px solid var(--ch-rule-strong);padding-top:26px;margin:0;line-height:1.7;}}
.right{{position:absolute;left:876px;top:62px;width:1068px;height:1024px;
  display:flex;flex-direction:column;gap:24px;}}
.tile{{background:var(--ch-paper-raised);border:2px solid var(--ch-rule);border-radius:16px;
  padding:22px 26px 18px;overflow:hidden;display:flex;flex-direction:column;min-width:0;}}
.tile svg{{width:100%;height:100%;display:block;flex:1;min-height:0;}}
.k{{font-family:var(--ch-font-mono);font-size:17px;letter-spacing:.13em;text-transform:uppercase;
  color:var(--ch-soft);margin:0 0 10px;flex:none;}}
.r1{{height:434px;display:flex;gap:24px;flex:none;}}
.r1 .tile{{flex:1;min-width:0;}}
.r2{{height:290px;flex:none;}}
.r3{{height:252px;flex:none;}}
</style></head>
<body>
<div class="cover">
  <div class="left">
    <p class="eyebrow">HQ Pack</p>
    <h1>Charts<br><em>that ship</em></h1>
    <p class="tag">Plain-language data in. Publishable HTML out.</p>
    <p class="meta">27 TYPES · 3 FAMILIES<br>3 REPORT SHEETS · 0 DEPENDENCIES</p>
  </div>
  <div class="right">
    <div class="r1">
      <div class="tile"><p class="k">{label['plain.bar-ranked']}</p>{b['plain.bar-ranked']}</div>
      <div class="tile"><p class="k">{label['plain.ring']}</p>{b['plain.ring']}</div>
    </div>
    <div class="tile r2"><p class="k">{label['signal.kpi-spark']}</p>{b['signal.kpi-spark']}</div>
    <div class="tile r3"><p class="k">{label['ledger.year-heat']}</p>{b['ledger.year-heat']}</div>
  </div>
</div>
</body></html>"""


def downscale(png: Path, jpg: Path) -> None:
    if shutil.which("sips"):
        subprocess.run(["sips", "-Z", "1024", "--setProperty", "format", "jpeg",
                        "--setProperty", "formatOptions", "92", str(png), "--out", str(jpg)],
                       check=True, capture_output=True)
    elif shutil.which("magick") or shutil.which("convert"):
        tool = shutil.which("magick") or shutil.which("convert")
        subprocess.run([tool, str(png), "-resize", "1024x574", "-quality", "92", str(jpg)], check=True)
    else:
        sys.exit("make-cover: need `sips` (macOS) or ImageMagick to downscale.")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--html", action="store_true", help="write the intermediate HTML and stop")
    a = ap.parse_args()

    html = compose(extract())

    if a.html:
        p = ROOT / "cover.source.html"
        p.write_text(html, encoding="utf-8")
        print(f"wrote {p}")
        return 0

    chrome = find_chrome()
    if not chrome:
        sys.exit("make-cover: no headless Chrome found. Pass --html and render it yourself.")

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "cover.html"
        src.write_text(html, encoding="utf-8")
        png = Path(td) / "cover.png"
        subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        "--virtual-time-budget=6000", "--window-size=2048,1148",
                        f"--screenshot={png}", src.as_uri()], capture_output=True)
        if not png.exists():
            sys.exit("make-cover: Chrome produced no screenshot.")
        downscale(png, OUT_JPG)

    print(f"wrote {OUT_JPG} (1024x574)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
