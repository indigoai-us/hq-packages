#!/usr/bin/env python3
"""Self-test for hq-pack-charts: registry integrity, gallery coverage, README
counts, stylesheet class coverage, and linter rule behaviour in both directions.

    python3 scripts/test-lint.py

Standard library only (a tiny YAML subset reader is included so PyYAML is not
required).
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REG = ROOT / "knowledge" / "charts" / "types" / "registry.yaml"
TYPES_README = ROOT / "knowledge" / "charts" / "types" / "README.md"
PACK_README = ROOT / "README.md"
CSS = ROOT / "assets" / "chart.css"
LINT = ROOT / "scripts" / "lint-chart.py"

fails = 0


def check(cond, msg):
    global fails
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails += 1


def read_registry():
    """Minimal reader for the registry's flat list-of-maps shape."""
    types, cur = [], None
    for raw in REG.read_text().splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        m = re.match(r"^  - id: (.+)$", line)
        if m:
            cur = {"id": m.group(1).strip()}
            types.append(cur)
            continue
        m = re.match(r"^    ([a-z_]+): (.*)$", line)
        if m and cur is not None:
            cur[m.group(1)] = m.group(2).strip().strip('"')
    return types


def lint(html: str) -> set[str]:
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, dir=ROOT / "assets") as f:
        f.write(html)
        p = Path(f.name)
    try:
        subprocess.run([sys.executable, str(ROOT / "scripts" / "sync-assets.py"), str(p)], capture_output=True)
        out = subprocess.run([sys.executable, str(LINT), str(p)], capture_output=True, text=True).stdout
    finally:
        p.unlink(missing_ok=True)
    return set(re.findall(r"\b(CH\d{3})\b", out))


def fixture(svg_inner: str, card_extra: str = "", html_attrs: str = 'data-ch-palette="mono"', head_extra: str = "") -> str:
    return f"""<!DOCTYPE html><html lang="en" {html_attrs}><head><meta charset="utf-8"><title>t</title>{head_extra}
<style>/* ch:css:start */
/* ch:css:end */</style></head><body><main class="ch-page"><div class="ch-grid">
<figure class="ch-card" data-ch-type="plain.bar-ranked">{card_extra}
<h2 class="ch-card__title">A finding</h2><p class="ch-card__sub">marks · unit · range</p>
<svg class="ch" viewBox="0 0 520 300" role="img" aria-labelledby="t1 d1"><title id="t1">t</title><desc id="d1">Finding stated in prose for the reader.</desc>
{svg_inner}</svg><p class="ch-card__src">src</p></figure></div></main></body></html>"""


def main() -> int:
    print("registry")
    types = read_registry()
    ids = [t["id"] for t in types]
    check(len(ids) == len(set(ids)), "ids are unique")
    check(all(t.get("family") in ("ledger", "plain", "signal") for t in types), "every type has a known family")
    check(all(t.get("tier") in ("primary", "fallback") for t in types), "every type has a tier")
    check(all(t.get("status") in ("spec", "planned") for t in types), "every type has a status")
    check(all(t["id"].startswith(t["family"] + ".") for t in types), "id prefix matches family")
    spec = [t for t in types if t["status"] == "spec"]
    planned = [t for t in types if t["status"] == "planned"]

    print("galleries")
    for fam in ("ledger", "plain", "signal"):
        g = ROOT / "assets" / "galleries" / f"{fam}.html"
        if not g.exists():
            check(False, f"{fam}.html exists")
            continue
        html = g.read_text()
        present = set(re.findall(r'data-ch-type="([^"]+)"', html))
        want = {t["id"] for t in spec if t["family"] == fam}
        missing = want - present
        extra = present - {t["id"] for t in types}
        check(not missing, f"{fam}.html has a card for every spec type" + (f" — missing {sorted(missing)}" if missing else ""))
        check(not extra, f"{fam}.html has no unregistered type" + (f" — extra {sorted(extra)}" if extra else ""))
        for t in spec:
            if t["family"] == fam and t["id"] in present:
                check(t["card"] in html, f"{t['id']} card title present: {t['card']!r}")
        for t in planned:
            check(t["id"] not in present, f"planned {t['id']} is not drawn")

    print("readme counts")
    if TYPES_README.exists():
        tr = TYPES_README.read_text()
        for t in types:
            check(f"`{t['id']}`" in tr, f"types/README lists {t['id']}")
    else:
        check(False, "types/README.md exists")
    pr = PACK_README.read_text() if PACK_README.exists() else ""
    m = re.search(r"(\d+) types", pr)
    check(bool(m) and int(m.group(1)) == len(types), f"pack README type count == {len(types)}")
    m = re.search(r"(\d+) with a gallery card", pr)
    check(bool(m) and int(m.group(1)) == len(spec), f"pack README spec count == {len(spec)}")

    print("stylesheet")
    css = CSS.read_text()
    classes = set(re.findall(r"\.(ch[a-z0-9_-]*)", css))
    for need in ("ch-mark", "ch-hero", "ch-quiet", "ch-line", "ch-t-axis", "ch-grow", "ch-rise", "ch-pop", "ch-draw", "ch-fade",
                 "ch-card__title", "ch-card__sub", "ch-card__src", "ch-sheet__title", "ch-kpi__value"):
        check(need in classes, f"chart.css defines .{need}")
    for pal in ("slate", "moss", "ember"):
        check(f'[data-ch-palette="{pal}"]' in css, f"palette {pal} defined")

    print("linter — should fail")
    check("CH101" in lint(fixture('<rect class="ch-mark" fill="#c00" x="0" y="0" width="10" height="10"/>')), "CH101 colour literal")
    check("CH103" in lint(fixture('<rect class="ch-mark" style="fill:red" x="0" y="0" width="10" height="10"/>')), "CH103 style attribute")
    check("CH110" in lint(fixture('<rect class="ch-mark" x="0" y="0" width="10" height="10"/>', head_extra='<script src="https://cdn.example/x.js"></script>')), "CH110 external script")
    check("CH113" in lint(fixture('<rect class="ch-mark" x="0" y="0" width="10" height="10"/>', head_extra='<script>var v=Math.random()</script>')), "CH113 Math.random")
    check("CH130" in lint(fixture('<rect id="dup" class="ch-mark" x="0" y="0" width="10" height="10"/><rect id="dup" class="ch-mark" x="0" y="20" width="10" height="10"/>')), "CH130 duplicate id")
    check("CH150" in lint(fixture('<text class="ch-t-axis" font-size="5" x="0" y="10">x</text>')), "CH150 sub-floor type")
    check("CH152" in lint(fixture('<rect class="ch-mark" x="0" y="0" width="10" height="10"/>', html_attrs='data-ch-palette="neon"')), "CH152 unknown palette")
    check("CH170" in lint(fixture('<rect class="ch-nope" x="0" y="0" width="10" height="10"/>')), "CH170 unknown class")
    check("CH181" in lint(fixture('<g><rect class="ch-mark" x="0" y="0" width="100" height="10"><title>a · 100</title></rect>'
                                  '<rect class="ch-mark" x="0" y="20" width="50" height="10"><title>b · 50</title></rect>'
                                  '<rect class="ch-mark" x="0" y="40" width="90" height="10"><title>c · 25</title></rect></g>')), "CH181 non-proportional bars")
    bad_html = fixture('<rect class="ch-mark" x="0" y="0" width="10" height="10"/>').replace('<h2 class="ch-card__title">A finding</h2>', "")
    check("CH160" in lint(bad_html), "CH160 missing conclusion")

    print("linter — should pass")
    good = lint(fixture('<g><rect class="ch-mark ch-grow" x="0" y="0" width="100" height="10"><title>a · 100</title></rect>'
                        '<rect class="ch-mark ch-grow ch-d1" x="0" y="20" width="50" height="10"><title>b · 50</title></rect>'
                        '<rect class="ch-mark ch-grow ch-d2" x="0" y="40" width="25" height="10"><title>c · 25</title></rect>'
                        '<text class="ch-t-label" x="0" y="60">a</text></g>'))
    errs = {c for c in good if c not in ("CH104", "CH161", "CH162", "CH163", "CH144", "CH180", "CH181")}
    check(not errs, f"clean fixture has no errors ({sorted(errs)})")

    print(f"\n{fails} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
