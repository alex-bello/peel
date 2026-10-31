#!/usr/bin/env python3
"""Render a two-line text label to an 8-bit grayscale PNG. Standard library only."""

import argparse
import struct
import sys
import zlib

# 5x7 bitmap font. '#' is ink.
_GLYPHS = {
    "A": ".###.|#...#|#...#|#####|#...#|#...#|#...#",
    "B": "####.|#...#|#...#|####.|#...#|#...#|####.",
    "C": ".####|#....|#....|#....|#....|#....|.####",
    "D": "####.|#...#|#...#|#...#|#...#|#...#|####.",
    "E": "#####|#....|#....|####.|#....|#....|#####",
    "F": "#####|#....|#....|####.|#....|#....|#....",
    "G": ".####|#....|#....|#.###|#...#|#...#|.###.",
    "H": "#...#|#...#|#...#|#####|#...#|#...#|#...#",
    "I": ".###.|..#..|..#..|..#..|..#..|..#..|.###.",
    "J": "..###|...#.|...#.|...#.|...#.|#..#.|.##..",
    "K": "#...#|#..#.|#.#..|##...|#.#..|#..#.|#...#",
    "L": "#....|#....|#....|#....|#....|#....|#####",
    "M": "#...#|##.##|#.#.#|#.#.#|#...#|#...#|#...#",
    "N": "#...#|##..#|#.#.#|#..##|#...#|#...#|#...#",
    "O": ".###.|#...#|#...#|#...#|#...#|#...#|.###.",
    "P": "####.|#...#|#...#|####.|#....|#....|#....",
    "Q": ".###.|#...#|#...#|#...#|#.#.#|#..#.|.##.#",
    "R": "####.|#...#|#...#|####.|#.#..|#..#.|#...#",
    "S": ".####|#....|#....|.###.|....#|....#|####.",
    "T": "#####|..#..|..#..|..#..|..#..|..#..|..#..",
    "U": "#...#|#...#|#...#|#...#|#...#|#...#|.###.",
    "V": "#...#|#...#|#...#|#...#|#...#|.#.#.|..#..",
    "W": "#...#|#...#|#...#|#.#.#|#.#.#|##.##|#...#",
    "X": "#...#|#...#|.#.#.|..#..|.#.#.|#...#|#...#",
    "Y": "#...#|#...#|.#.#.|..#..|..#..|..#..|..#..",
    "Z": "#####|....#|...#.|..#..|.#...|#....|#####",
    "0": ".###.|#...#|#..##|#.#.#|##..#|#...#|.###.",
    "1": "..#..|.##..|..#..|..#..|..#..|..#..|.###.",
    "2": ".###.|#...#|....#|...#.|..#..|.#...|#####",
    "3": "#####|...#.|..#..|...#.|....#|#...#|.###.",
    "4": "...#.|..##.|.#.#.|#..#.|#####|...#.|...#.",
    "5": "#####|#....|####.|....#|....#|#...#|.###.",
    "6": "..##.|.#...|#....|####.|#...#|#...#|.###.",
    "7": "#####|....#|...#.|..#..|.#...|.#...|.#...",
    "8": ".###.|#...#|#...#|.###.|#...#|#...#|.###.",
    "9": ".###.|#...#|#...#|.####|....#|...#.|.##..",
    "-": ".....|.....|.....|#####|.....|.....|.....",
    ":": ".....|..#..|.....|.....|.....|..#..|.....",
    ".": ".....|.....|.....|.....|.....|.##..|.##..",
    "/": "....#|....#|...#.|..#..|.#...|#....|#....",
    " ": ".....|.....|.....|.....|.....|.....|.....",
}
_GLYPH_W, _GLYPH_H, _ADVANCE = 5, 7, 6  # advance includes 1 column of spacing


def _glyph(ch):
    rows = _GLYPHS.get(ch.upper())
    return rows.split("|") if rows else None


def _text_width_cols(text):
    n = sum(1 for ch in text if _glyph(ch))
    return max(n * _ADVANCE - 1, 0)


def _draw_text(canvas, width, text, x0, y0, scale):
    x = x0
    for ch in text:
        rows = _glyph(ch)
        if not rows:
            continue
        for ry, row in enumerate(rows):
            for rx, cell in enumerate(row):
                if cell != "#":
                    continue
                for dy in range(scale):
                    line = canvas[y0 + ry * scale + dy]
                    start = x + rx * scale
                    line[start:start + scale] = b"\x00" * scale
        x += _ADVANCE * scale


def _fit_scale(text, box_w, box_h):
    cols = _text_width_cols(text)
    if cols == 0:
        return 0
    return max(min(box_w // cols, box_h // _GLYPH_H), 1)


def _chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def _write_png(path, width, height, canvas, dpi=300):
    raw = b"".join(b"\x00" + bytes(row) for row in canvas)  # filter type 0 per scanline
    ppm = round(dpi / 0.0254)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
        + _chunk(b"pHYs", struct.pack(">IIB", ppm, ppm, 1))
        + _chunk(b"IDAT", zlib.compress(raw, 9))
        + _chunk(b"IEND", b"")
    )
    with open(path, "wb") as fh:
        fh.write(png)


def render(width, height, line1, line2, border=6):
    canvas = [bytearray(b"\xff" * width) for _ in range(height)]
    for y in range(height):
        for x in range(width):
            if x < border or y < border or x >= width - border or y >= height - border:
                canvas[y][x] = 0

    margin = max(min(width, height) // 10, border * 3)
    inner_w, inner_h = width - 2 * margin, height - 2 * margin
    gap = inner_h // 10

    # Line 1 gets ~60% of the height, line 2 the rest.
    h1 = (inner_h - gap) * 6 // 10
    h2 = inner_h - gap - h1
    for text, box_h, y_top in ((line1, h1, margin), (line2, h2, margin + h1 + gap)):
        scale = _fit_scale(text, inner_w, box_h)
        if not scale:
            continue
        text_w = _text_width_cols(text) * scale
        x0 = margin + (inner_w - text_w) // 2
        y0 = y_top + (box_h - _GLYPH_H * scale) // 2
        _draw_text(canvas, width, text, x0, y0, scale)
    return canvas


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True, help="output PNG path")
    ap.add_argument("--size", default="1050x330", help="WIDTHxHEIGHT in pixels (default 1050x330)")
    ap.add_argument("--line1", default="PEEL TEST")
    ap.add_argument("--line2", default="")
    args = ap.parse_args()

    try:
        width, height = (int(v) for v in args.size.lower().split("x"))
        if width < 50 or height < 50:
            raise ValueError
    except ValueError:
        sys.exit(f"--size must look like 1050x330 (each side >= 50), got {args.size!r}")

    _write_png(args.out, width, height, render(width, height, args.line1, args.line2))


if __name__ == "__main__":
    main()
