"""Build the shared Franklin README assets into <repo>/.github/brand.

Usage, from the franklin/ folder that holds the repos:
    uv run --with fonttools --with uharfbuzz python3 <repo>/.github/brand/build_readme_assets.py <repo>

Writes lockup-light.svg / lockup-dark.svg (README hero), frank-signature-light/dark.svg
and series/<project>.svg (footer tiles). Marks come from each project's committed
brand files; the dark lockups use the monochrome cut-out marks from
visual-design-2026-11-23/refined. The name is set in Inter SemiBold and outlined,
so GitHub never substitutes a font. The signature is the one the Frank series uses.
"""
import re, subprocess, sys, pathlib

import uharfbuzz as hb
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

F = pathlib.Path(__file__).resolve().parents[3]
repo = sys.argv[1].strip("/")
out = F / repo / ".github/brand"
(out / "series").mkdir(parents=True, exist_ok=True)
REFINED = F / "visual-design-2026-11-23/refined"
FONT = pathlib.Path.home() / "Library/Fonts/InterVariable.ttf"
PAPER = "#f4efe6"


def committed(repo_name, path):
    return subprocess.run(["git", "-C", str(F / repo_name), "show", f"HEAD:{path}"],
                          check=True, capture_output=True, text=True).stdout


def inner(s):
    vb = re.search(r'viewBox="([^"]+)"', s).group(1)
    body = re.sub(r"^.*?<svg[^>]*>|</svg>\s*$", "", s, flags=re.S)
    body = re.sub(r'\s(?:affinity|serif|sodipodi|inkscape):[\w-]+="[^"]*"', "", body)  # editor metadata
    return vb, re.sub(r"<title[^>]*>.*?</title>", "", body, flags=re.S)


# Each mark: (light source, dark source, ink colour)
roc = committed("roc-ui", "public/favicon.svg")
roc_shape = re.sub(r"<rect[^>]*/>", "", roc, count=1)
MARKS = {
    "leftopen": ("LeftOpen", committed("leftopen", "assets/logo.svg"),
                 (REFINED / "leftopen/mono.svg").read_text(), "#211811"),
    "roc-ui": ("ROC", roc_shape.replace("#FFFFFF", "#252525"),
               roc_shape.replace("#FFFFFF", PAPER), "#252525"),
    "token-flow": ("Token Flow", committed("token-flow", "token_tap/viewer_assets/token-flow-logo.svg"),
                   (REFINED / "token-flow/mono.svg").read_text(), "#020202"),
}


def tile(name, title, bg, source, pad, edge):
    vb, body = inner(source)
    box = 256 - 2 * pad
    stroke = {"ink": ' stroke="#1f1e1b" stroke-opacity="0.14" stroke-width="4"',
              "paper": f' stroke="{PAPER}" stroke-opacity="0.28" stroke-width="4"'}.get(edge, "")
    (out / "series" / f"{name}.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" role="img"><title>{title}</title>'
        f'<rect x="2" y="2" width="252" height="252" rx="56" fill="{bg}"{stroke}/>'
        f'<svg x="{pad}" y="{pad}" width="{box}" height="{box}" viewBox="{vb}">{body}</svg></svg>\n')


tile("leftopen", "LeftOpen", "#ffffff", MARKS["leftopen"][1], 40, "ink")
tile("roc-ui", "ROC", "#252525", roc, 0, "paper")
tile("token-flow", "Token Flow", "#ffffff", MARKS["token-flow"][1], 52, "ink")

sig = (F.parent / "frank/news-metro/public/frank-signature.svg").read_text()
(out / "frank-signature-light.svg").write_text(sig)
(out / "frank-signature-dark.svg").write_text(sig.replace("#171916", PAPER))


def wordmark(text, size):
    """Outlined, kerned Inter SemiBold. Returns (path d, advance width)."""
    font = TTFont(FONT)
    instantiateVariableFont(font, {"wght": 600, "opsz": 32}, inplace=True)
    blob = hb.Blob.from_file_path(str(FONT))
    hbfont = hb.Font(hb.Face(blob))
    hbfont.set_variations({"wght": 600, "opsz": 32})
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(hbfont, buf, {"kern": True, "liga": True})
    order = font.getGlyphOrder()
    glyphs = font.getGlyphSet()
    scale = size / font["head"].unitsPerEm
    pen = SVGPathPen(glyphs)
    x = 0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        glyphs[order[info.codepoint]].draw(TransformPen(pen, (scale, 0, 0, -scale, (x + pos.x_offset) * scale, 0)))
        x += pos.x_advance
    return pen.getCommands(), x * scale


def lockup(dark):
    title, light_src, dark_src, ink = MARKS[repo]
    vb, body = inner(dark_src if dark else light_src)
    _, _, vw, vh = map(float, vb.split())
    h = 100
    w = h * vw / vh
    d, tw = wordmark(title, 78)
    cap = 78 * 1490 / 2048
    gap = 26
    colour = PAPER if dark else ink
    if dark:
        body = re.sub(r'fill="(?:#[0-9a-fA-F]{3,6}|currentColor)"', f'fill="{PAPER}"', body)
        if 'fill=' not in body:
            body = f'<g fill="{PAPER}">{body}</g>'
    total = w + gap + tw
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {total:.1f} {h}" role="img"><title>{title}</title>'
            f'<svg width="{w:.2f}" height="{h}" viewBox="{vb}">{body}</svg>'
            f'<path transform="translate({w + gap:.2f} {h / 2 + cap / 2:.2f})" fill="{colour}" d="{d}"/></svg>\n')


(out / "lockup-light.svg").write_text(lockup(False))
(out / "lockup-dark.svg").write_text(lockup(True))
print(f"{repo}: wrote {sorted(str(p.relative_to(out)) for p in out.rglob('*.svg'))}")
