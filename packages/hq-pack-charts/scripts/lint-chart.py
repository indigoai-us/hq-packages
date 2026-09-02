#!/usr/bin/env python3
"""Lint an HQ chart file against the chart.css contract and the honesty rules.

    python3 scripts/lint-chart.py path.html [more.html ...]
    python3 scripts/lint-chart.py --all            # every html under assets/
    python3 scripts/lint-chart.py --json path.html

Exit 1 on any ERROR. Warnings print but do not fail.

Rules
  CH101  colour literal in an SVG attribute        — use a ch- class
  CH102  font-family in an SVG attribute           — use a ch-t- class
  CH103  style= attribute inside the SVG           — use a ch- class
  CH104  SVG drawing element carries no ch- class  (warn)
  CH110  external script                           — charts are self-contained
  CH111  external resource that is not the allowed webfont stylesheet
  CH112  external image reference                  — SVG must be inline
  CH113  Math.random() in a script                 — demo data must be deterministic
  CH120  inlined stylesheet missing / malformed / stale
  CH130  duplicate id attribute
  CH140  <svg class="ch"> is missing role="img"
  CH141  <svg> is missing a <title>
  CH142  <svg> is missing a <desc>
  CH143  aria-labelledby points at an id that does not exist
  CH144  <desc> looks like a list of shapes, not a conclusion   (warn)
  CH150  text font-size below the floor (7px half-width, 6px wide)
  CH151  more than one palette declared in the file
  CH152  unknown data-ch-palette value
  CH160  card has no h2 conclusion title
  CH161  card has no .ch-card__sub legend line             (warn)
  CH162  card has no .ch-card__src source line             (warn)
  CH163  card has no data-ch-type                          (warn)
  CH170  unknown ch- class — typo, or a class the stylesheet lost
  CH180  element sits outside the viewBox                  (warn)
  CH181  bar/column heights within one group are not proportional to their
         <title> values (checks "label · 123" titles)      (warn)

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CSS_PATH = ROOT / "assets" / "chart.css"

ERROR, WARN = "error", "warn"
RULES = {
    "CH101": (ERROR, "colour literal in an SVG attribute — use a ch- class"),
    "CH102": (ERROR, "font-family in an SVG attribute — use a ch-t- class"),
    "CH103": (ERROR, "style= attribute inside the SVG — use a ch- class"),
    "CH104": (WARN, "SVG drawing element carries no ch- class"),
    "CH110": (ERROR, "external <script> — charts are self-contained"),
    "CH111": (ERROR, "external resource that is not the allowed webfont stylesheet"),
    "CH112": (ERROR, "external image reference — SVG must be inline"),
    "CH113": (ERROR, "Math.random() — demo data must be deterministic"),
    "CH120": (ERROR, "inlined stylesheet is missing, malformed, or stale"),
    "CH130": (ERROR, "duplicate id"),
    "CH140": (ERROR, '<svg class="ch"> is missing role="img"'),
    "CH141": (ERROR, "<svg> is missing a <title>"),
    "CH142": (ERROR, "<svg> is missing a <desc>"),
    "CH143": (ERROR, "aria-labelledby points at an id that does not exist"),
    "CH144": (WARN, "<desc> looks like a list of shapes, not a conclusion"),
    "CH150": (ERROR, "text font-size below the floor"),
    "CH151": (ERROR, "more than one palette declared in the file"),
    "CH152": (ERROR, "unknown data-ch-palette value"),
    "CH160": (ERROR, "card has no <h2 class=\"ch-card__title\"> conclusion"),
    "CH161": (WARN, "card has no .ch-card__sub legend line"),
    "CH162": (WARN, "card has no .ch-card__src source line"),
    "CH163": (WARN, "card has no data-ch-type"),
    "CH170": (ERROR, "unknown ch- class"),
    "CH180": (WARN, "element sits outside the viewBox"),
    "CH181": (WARN, "bar lengths in a group are not proportional to their title values"),
}

PALETTES = {"mono", "slate", "moss", "ember"}
DRAWING = {"rect", "circle", "ellipse", "line", "polyline", "polygon", "path", "text", "tspan", "use"}
COLOUR_ATTRS = {"fill", "stroke", "stop-color", "flood-color", "lighting-color", "color"}
COLOUR_RE = re.compile(r"^(#|rgb|hsl|url\(#|[a-z]+$)")
SAFE_COLOUR_VALUES = {"none", "currentcolor", "inherit", "transparent"}
FONT_STACK_ALLOWED = ("https://fonts.googleapis.com/", "https://fonts.gstatic.com")
VB_RE = re.compile(r"^\s*(-?[\d.]+)\s+(-?[\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$")
TITLE_VAL_RE = re.compile(r"[·:]\s*(-?[\d][\d,]*\.?\d*)")
SHAPE_WORDS = ("rect", "circle", "line", "path", "arrow", "box", "shape")


def css_classes(css: str) -> set[str]:
    return set(re.findall(r"\.(ch[a-z0-9_-]*)", css))


class Node:
    __slots__ = ("tag", "attrs", "children", "text", "parent", "line")

    def __init__(self, tag, attrs, parent, line):
        self.tag, self.attrs, self.parent, self.line = tag, dict(attrs), parent, line
        self.children, self.text = [], ""

    def iter(self):
        yield self
        for c in self.children:
            yield from c.iter()

    def cls(self):
        return self.attrs.get("class", "").split()


VOID = {"meta", "link", "br", "img", "input", "hr"}


class TreeParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#root", [], None, 0)
        self.cur = self.root
        self.scripts = []
        self.styles = []
        self._in = None

    def handle_starttag(self, tag, attrs):
        n = Node(tag, attrs, self.cur, self.getpos()[0])
        self.cur.children.append(n)
        if tag in ("script", "style"):
            self._in = (tag, n)
        if tag not in VOID:
            self.cur = n

    def handle_startendtag(self, tag, attrs):
        self.cur.children.append(Node(tag, attrs, self.cur, self.getpos()[0]))

    def handle_endtag(self, tag):
        n = self.cur
        while n is not self.root and n.tag != tag:
            n = n.parent
        if n is not self.root:
            self.cur = n.parent
        if self._in and self._in[0] == tag:
            (self.scripts if tag == "script" else self.styles).append(self._in[1])
            self._in = None

    def handle_data(self, data):
        self.cur.text += data


class Linter:
    def __init__(self, path: Path, css: str):
        self.path, self.css = path, css
        self.known = css_classes(css)
        self.findings = []

    def add(self, code, detail="", line=0):
        sev, msg = RULES[code]
        self.findings.append({"code": code, "severity": sev, "message": msg, "detail": detail, "line": line})

    # ── file-level ────────────────────────────────────────────────────────
    def run(self):
        src = self.path.read_text(encoding="utf-8")
        p = TreeParser()
        p.feed(src)
        self.check_css(src)
        self.check_external(p)
        self.check_palette(p)
        self.check_ids(p)
        for sc in p.scripts:
            if "Math.random" in sc.text:
                self.add("CH113", "", sc.line)
        for n in p.root.iter():
            if n.tag == "svg" and "ch" in n.cls():
                self.check_svg(n)
            if n.tag in ("figure", "div", "section") and "ch-card" in n.cls():
                self.check_card(n)
        return self.findings

    def check_css(self, src):
        m = re.search(r"/\* ch:css:start \*/(.*?)/\* ch:css:end \*/", src, re.S)
        if not m:
            self.add("CH120", "marker pair not found")
            return
        body = m.group(1)
        if not body.strip():
            self.add("CH120", "empty — run scripts/sync-assets.py")
            return
        import hashlib
        fp = hashlib.sha256(self.css.encode()).hexdigest()[:12]
        if fp not in body[:400]:
            self.add("CH120", "stale fingerprint — run scripts/sync-assets.py")

    def check_external(self, p):
        for n in p.root.iter():
            if n.tag == "script" and n.attrs.get("src"):
                self.add("CH110", n.attrs["src"], n.line)
            if n.tag == "link":
                href = n.attrs.get("href", "")
                if href.startswith(("http:", "https:", "//")) and not href.startswith(FONT_STACK_ALLOWED):
                    self.add("CH111", href, n.line)
            if n.tag in ("img", "image"):
                self.add("CH112", n.attrs.get("src") or n.attrs.get("href", ""), n.line)

    def check_palette(self, p):
        vals = set()
        for n in p.root.iter():
            v = n.attrs.get("data-ch-palette")
            if v is not None:
                vals.add(v)
                if v not in PALETTES:
                    self.add("CH152", v, n.line)
        if len(vals) > 1:
            self.add("CH151", ", ".join(sorted(vals)))

    def check_ids(self, p):
        seen = {}
        for n in p.root.iter():
            i = n.attrs.get("id")
            if i:
                if i in seen:
                    self.add("CH130", i, n.line)
                seen[i] = n
        self.ids = seen

    # ── svg-level ─────────────────────────────────────────────────────────
    def check_svg(self, svg):
        if svg.attrs.get("role") != "img":
            self.add("CH140", "", svg.line)
        title = next((c for c in svg.children if c.tag == "title"), None)
        desc = next((c for c in svg.children if c.tag == "desc"), None)
        if title is None:
            self.add("CH141", "", svg.line)
        if desc is None:
            self.add("CH142", "", svg.line)
        elif any(w in desc.text.lower() for w in SHAPE_WORDS) and len(desc.text) < 60:
            self.add("CH144", desc.text.strip()[:60], desc.line)
        for ref in svg.attrs.get("aria-labelledby", "").split():
            if ref not in self.ids:
                self.add("CH143", ref, svg.line)

        vb = VB_RE.match(svg.attrs.get("viewBox", ""))
        box = tuple(float(x) for x in vb.groups()) if vb else None
        wide = box is not None and box[2] >= 700
        floor = 6.0 if wide else 7.0

        groups: dict[Node, list[tuple[float, float]]] = {}
        for n in svg.iter():
            if n is svg:
                continue
            a = n.attrs
            for k, v in a.items():
                lv = v.strip().lower()
                if k in COLOUR_ATTRS and lv not in SAFE_COLOUR_VALUES and COLOUR_RE.match(lv) and not lv.startswith("url(#"):
                    self.add("CH101", f'<{n.tag} {k}="{v}">', n.line)
                if k == "font-family":
                    self.add("CH102", f"<{n.tag}>", n.line)
                if k == "style":
                    self.add("CH103", f'<{n.tag} style="{v[:40]}">', n.line)
                if k == "font-size":
                    try:
                        px = float(v.replace("px", ""))
                        if px < floor:
                            self.add("CH150", f"{px}px < {floor}px", n.line)
                    except ValueError:
                        pass
            if n.tag in DRAWING:
                cl = [c for c in n.cls() if c.startswith("ch")]
                if not cl and n.tag not in ("tspan",):
                    self.add("CH104", f"<{n.tag}>", n.line)
                for c in n.cls():
                    if c.startswith("ch") and c not in self.known:
                        self.add("CH170", c, n.line)
                if box and n.tag in ("rect", "circle"):
                    self.check_bounds(n, box)
            if n.tag == "rect" and n.parent is not None:
                t = next((c for c in n.children if c.tag == "title"), None)
                m = TITLE_VAL_RE.search(t.text) if t else None
                if m:
                    try:
                        val = float(m.group(1).replace(",", ""))
                        w = float(n.attrs.get("width", 0)); h = float(n.attrs.get("height", 0))
                        groups.setdefault(n.parent, []).append((val, w, h))
                    except ValueError:
                        pass
        for parent, pairs in groups.items():
            if len(pairs) >= 3:
                # columns share a width and encode in height; bars share a
                # height and encode in width. Pick the axis that varies.
                ws = {round(w, 1) for _, w, _ in pairs}
                hs = {round(h, 1) for _, _, h in pairs}
                if len(ws) == 1 and len(hs) > 1:
                    lens = [(v, h) for v, _, h in pairs]
                elif len(hs) == 1 and len(ws) > 1:
                    lens = [(v, w) for v, w, _ in pairs]
                else:
                    lens = [(v, max(w, h)) for v, w, h in pairs]
                ratios = [ln / abs(v) for v, ln in lens if v != 0]
                if ratios and (max(ratios) - min(ratios)) / max(ratios) > 0.08:
                    self.add("CH181", f"{len(pairs)} bars, px-per-unit spread {min(ratios):.2f}–{max(ratios):.2f}", parent.line)

    def check_bounds(self, n, box):
        x0, y0, w, h = box
        try:
            if n.tag == "rect":
                x, y = float(n.attrs.get("x", 0)), float(n.attrs.get("y", 0))
                ww, hh = float(n.attrs.get("width", 0)), float(n.attrs.get("height", 0))
                if x < x0 - 1 or y < y0 - 1 or x + ww > x0 + w + 1 or y + hh > y0 + h + 1:
                    self.add("CH180", f"<rect x={x} y={y} w={ww} h={hh}>", n.line)
            else:
                cx, cy, r = (float(n.attrs.get(k, 0)) for k in ("cx", "cy", "r"))
                if cx - r < x0 - 1 or cy - r < y0 - 1 or cx + r > x0 + w + 1 or cy + r > y0 + h + 1:
                    self.add("CH180", f"<circle cx={cx} cy={cy} r={r}>", n.line)
        except ValueError:
            pass

    # ── card-level ────────────────────────────────────────────────────────
    def check_card(self, card):
        kids = list(card.iter())
        if not any(k.tag == "h2" and "ch-card__title" in k.cls() for k in kids):
            self.add("CH160", "", card.line)
        if not any("ch-card__sub" in k.cls() for k in kids):
            self.add("CH161", "", card.line)
        if not any("ch-card__src" in k.cls() for k in kids):
            self.add("CH162", "", card.line)
        if "data-ch-type" not in card.attrs:
            self.add("CH163", "", card.line)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", type=Path)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    files = list(a.files)
    if a.all:
        files += sorted((ROOT / "assets").rglob("*.html"))
    if not files:
        ap.error("no files")
    css = CSS_PATH.read_text(encoding="utf-8").rstrip("\n")
    failed = False
    out = {}
    for f in files:
        fs = Linter(f, css).run()
        out[str(f)] = fs
        errs = [x for x in fs if x["severity"] == ERROR]
        warns = [x for x in fs if x["severity"] == WARN]
        if errs:
            failed = True
        if not a.json:
            print(f"{f}: {len(errs)} error(s), {len(warns)} warning(s)")
            for x in fs:
                print(f"  {x['severity'].upper():5} {x['code']} L{x['line']:<5} {x['message']}" + (f" — {x['detail']}" if x['detail'] else ""))
    if a.json:
        print(json.dumps(out, indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
