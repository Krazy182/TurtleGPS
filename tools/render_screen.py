#!/usr/bin/env python3
"""Render a mock-harness screen dump (Screen:dumpRaw JSON) to a PNG.

usage: python3 tools/render_screen.py dump.json [out.png] [--font term_font.png]

With --font (or CC_FONT=...) pointing at CC:Tweaked's term_font.png the picture is
pixel-accurate; otherwise a system monospace font approximates the glyphs.
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

PALETTE = {
    "0": (240, 240, 240), "1": (242, 178, 51), "2": (229, 127, 216), "3": (153, 178, 242),
    "4": (222, 222, 108), "5": (127, 204, 25), "6": (242, 178, 204), "7": (76, 76, 76),
    "8": (153, 153, 153), "9": (76, 153, 178), "a": (178, 102, 229), "b": (51, 102, 204),
    "c": (127, 102, 76), "d": (87, 166, 78), "e": (204, 76, 76), "f": (17, 17, 17),
}
# Unicode stand-ins matching CC's font (only used without --font)
GLYPHS = {
    1: "☺", 2: "☻", 3: "♥", 4: "♦", 5: "♣", 6: "♠", 7: "•", 8: "◘", 11: "♂", 12: "♀",
    14: "♪", 15: "♫", 16: "►", 17: "◄", 18: "↕", 19: "‼", 20: "¶", 21: "§", 22: "▬",
    23: "↨", 24: "↑", 25: "↓", 26: "→", 27: "←", 28: "∟", 29: "↔", 30: "▲", 31: "▼", 127: "▒",
}
SCALE = 2
CW, CH = 6 * SCALE, 9 * SCALE


def load_font_atlas(path):
    atlas = Image.open(path).convert("RGBA")
    glyphs = {}
    for code in range(256):
        c, r = code % 16, code // 16
        cell = atlas.crop((1 + c * 8, 1 + r * 11, 1 + c * 8 + 6, 1 + r * 11 + 9))
        glyphs[code] = cell.split()[3].resize((CW, CH), Image.NEAREST)
    return glyphs


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--font")]
    font_path = os.environ.get("CC_FONT")
    for i, a in enumerate(sys.argv):
        if a == "--font" and i + 1 < len(sys.argv):
            font_path = sys.argv[i + 1]
            args.remove(font_path)
    src = args[0]
    out = args[1] if len(args) > 1 else src.rsplit(".", 1)[0] + ".png"
    data = json.load(open(src))
    w, h = data["w"], data["h"]
    img = Image.new("RGB", (w * CW, h * CH))
    d = ImageDraw.Draw(img)
    atlas = load_font_atlas(font_path) if font_path else None
    ttf = None
    if not atlas:
        try:
            ttf = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 15)
        except OSError:
            ttf = ImageFont.load_default()
    for y, row in enumerate(data["rows"]):
        for x, code in enumerate(row["t"]):
            fg, bg = PALETTE[row["f"][x]], PALETTE[row["b"][x]]
            x0, y0 = x * CW, y * CH
            d.rectangle([x0, y0, x0 + CW - 1, y0 + CH - 1], fill=bg)
            if atlas:
                img.paste(Image.new("RGB", (CW, CH), fg), (x0, y0), atlas[code])
                continue
            if 128 <= code < 160:
                bits = code - 128
                for i in range(5):
                    if bits & (1 << i):
                        px, py = i % 2, i // 2
                        d.rectangle([x0 + px * CW // 2, y0 + py * CH // 3,
                                     x0 + (px + 1) * CW // 2 - 1, y0 + (py + 1) * CH // 3 - 1], fill=fg)
                continue
            ch = GLYPHS.get(code, chr(code) if code >= 32 else None)
            if ch and ch != " ":
                d.text((x0 + 1, y0), ch, fill=fg, font=ttf)
    img.save(out)
    print(out)


if __name__ == "__main__":
    main()
