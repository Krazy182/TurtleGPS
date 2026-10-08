#!/usr/bin/env python3
"""Render a mock-harness screen dump (Screen:dumpRaw JSON) to a PNG.

usage: python3 tools/render_screen.py test/out/m1_monitor.json [out.png]
"""
import json
import sys

from PIL import Image, ImageDraw, ImageFont

PALETTE = {
    "0": (240, 240, 240), "1": (242, 178, 51), "2": (229, 127, 216), "3": (153, 178, 242),
    "4": (222, 222, 108), "5": (127, 204, 25), "6": (242, 178, 204), "7": (76, 76, 76),
    "8": (153, 153, 153), "9": (76, 153, 178), "a": (178, 102, 229), "b": (51, 102, 204),
    "c": (127, 102, 76), "d": (87, 166, 78), "e": (204, 76, 76), "f": (17, 17, 17),
}
GLYPHS = {
    1: "☺", 2: "☻", 3: "♥", 4: "♦", 5: "♣", 6: "♠", 7: "•", 8: "◘", 9: "○", 10: "◙",
    11: "♂", 12: "♀", 13: "♪", 14: "♫", 15: "☼", 16: "►", 17: "◄", 18: "↕", 19: "‼",
    20: "¶", 21: "§", 22: "▬", 23: "↨", 24: "↑", 25: "↓", 26: "→", 27: "←", 28: "∟",
    29: "↔", 30: "▲", 31: "▼", 127: "⌂",
}
CW, CH = 12, 18


def glyph(code):
    if code in GLYPHS:
        return GLYPHS[code]
    if 128 <= code < 160:
        return None  # teletext block, drawn as pixels
    return chr(code)


def main():
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else src.rsplit(".", 1)[0] + ".png"
    data = json.load(open(src))
    w, h = data["w"], data["h"]
    img = Image.new("RGB", (w * CW, h * CH))
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 15)
    except OSError:
        font = ImageFont.load_default()
    for y, row in enumerate(data["rows"]):
        for x, code in enumerate(row["t"]):
            fg, bg = PALETTE[row["f"][x]], PALETTE[row["b"][x]]
            x0, y0 = x * CW, y * CH
            d.rectangle([x0, y0, x0 + CW - 1, y0 + CH - 1], fill=bg)
            if 128 <= code < 160:
                bits = code - 128
                for i in range(6):
                    if bits & (1 << i) if i < 5 else False:
                        px, py = i % 2, i // 2
                        d.rectangle([x0 + px * CW // 2, y0 + py * CH // 3,
                                     x0 + (px + 1) * CW // 2 - 1, y0 + (py + 1) * CH // 3 - 1], fill=fg)
                continue
            ch = glyph(code)
            if ch and ch != " ":
                d.text((x0 + 1, y0), ch, fill=fg, font=font)
    img.save(out)
    print(out)


if __name__ == "__main__":
    main()
