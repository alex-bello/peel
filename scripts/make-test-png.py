#!/usr/bin/env python3
"""Render a two-line text label to an 8-bit grayscale PNG. Python standard library only.

    make-test-png.py --out label.png [--size 1050x330] [--dpi 300] [--line1 TEXT] [--line2 TEXT]

LPrint has no text renderer, so scripts/test-print.sh draws the text here and submits the PNG.
The image is white with a black border (so cropping by the printer shows up on the label), and
two lines of text drawn with a built-in 5x7 bitmap font, scaled up by a whole number to fill the
space and centred. Supported characters: A-Z (lowercase is drawn as uppercase), 0-9, space and
- : . / ; any other character is skipped with a note on stderr. Text that would not fit even at
the smallest scale is cut short (also with a note). The PNG carries a pHYs chunk (pixels per
metre, from --dpi) so a reader can tell the intended physical size.

Nothing here has been checked against the printer: how LPrint scales, rotates or crops this
image on the DYMO LabelWriter 450 Turbo is exactly what the hand-run test print is for.
"""

import argparse
import re
import struct
import sys
import zlib

# 5x7 bitmap font. '#' is ink. Rows are separated by '|'.
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
_GLYPH_H = 7
_ADVANCE = 6  # 5 glyph columns plus 1 column of spacing

BORDER = 6  # border thickness in pixels (0.5 mm at 300 dpi)
MIN_SIDE = 64  # smallest side for which both text lines can be laid out (see tests)
MAX_SIDE = 10000
MAX_PIXELS = 20_000_000  # keeps the in-memory canvas small enough for a Raspberry Pi 3B
DEFAULT_SIZE = "1050x330"
DEFAULT_DPI = 300


def _glyph(ch):
    """Rows of the glyph for ch (lowercase maps to uppercase), or None if unsupported."""
    if not ch.isascii():
        return None
    rows = _GLYPHS.get(ch.upper())
    return rows.split("|") if rows else None


def split_supported(text):
    """Return (kept, skipped): text with unsupported characters removed, and those characters."""
    kept = "".join(ch for ch in text if _glyph(ch))
    skipped = [ch for ch in text if not _glyph(ch)]
    return kept, skipped


def text_width_cols(text):
    """Width of text in font columns (before scaling). Unsupported characters count as zero."""
    n = sum(1 for ch in text if _glyph(ch))
    return max(n * _ADVANCE - 1, 0)


def fit_scale(text, box_w, box_h):
    """Largest whole-number scale at which text fits the box; 0 if it does not fit at 1."""
    cols = text_width_cols(text)
    if cols == 0:
        return 0
    scale = min(box_w // cols, box_h // _GLYPH_H)
    return scale if scale >= 1 else 0


def _draw_text(canvas, text, x0, y0, scale):
    x = x0
    ink = b"\x00" * scale
    for ch in text:
        rows = _glyph(ch)
        if not rows:
            continue
        for ry, row in enumerate(rows):
            for rx, cell in enumerate(row):
                if cell != "#":
                    continue
                start = x + rx * scale
                for dy in range(scale):
                    canvas[y0 + ry * scale + dy][start:start + scale] = ink
        x += _ADVANCE * scale


def _chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def encode_png(width, height, canvas, dpi=DEFAULT_DPI):
    """Encode rows of 8-bit gray pixels as a PNG with an IHDR, pHYs, IDAT and IEND chunk."""
    raw = b"".join(b"\x00" + bytes(row) for row in canvas)  # filter type 0 on every scanline
    ppm = round(dpi / 0.0254)  # pixels per metre
    return (
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))  # 8-bit grayscale
        + _chunk(b"pHYs", struct.pack(">IIB", ppm, ppm, 1))  # unit 1 = metre
        + _chunk(b"IDAT", zlib.compress(raw, 9))
        + _chunk(b"IEND", b"")
    )


def render(width, height, line1, line2, notes=None):
    """Draw the label; return the canvas (a list of `height` bytearrays of `width` gray pixels).

    notes, if given, is a list that receives one human-readable string per skipped character
    set or truncated line.
    """
    notes = notes if notes is not None else []
    white, black = b"\xff", b"\x00"
    canvas = [bytearray(white * width) for _ in range(height)]
    for y in range(height):
        if y < BORDER or y >= height - BORDER:
            canvas[y][:] = black * width
        else:
            canvas[y][:BORDER] = black * BORDER
            canvas[y][width - BORDER:] = black * BORDER

    margin = max(min(width, height) // 10, BORDER * 3)
    inner_w, inner_h = width - 2 * margin, height - 2 * margin
    gap = inner_h // 10
    h1 = (inner_h - gap) * 6 // 10  # line 1 gets about 60% of the height, line 2 the rest
    h2 = inner_h - gap - h1

    for number, (text, box_h, y_top) in enumerate(
        ((line1, h1, margin), (line2, h2, margin + h1 + gap)), start=1
    ):
        kept, skipped = split_supported(text)
        if skipped:
            notes.append(
                f"line {number}: skipped unsupported character(s) "
                + " ".join(repr(c) for c in dict.fromkeys(skipped))
                + " (supported: A-Z, 0-9, space and - : . /)"
            )
        scale = fit_scale(kept, inner_w, box_h)
        if not scale and kept and box_h >= _GLYPH_H:
            # Too long even at scale 1: keep as many characters as fit across the label.
            fits = (inner_w + 1) // _ADVANCE
            kept = kept[:fits]
            notes.append(f"line {number}: too long for a {width}-pixel-wide label, cut to {fits} characters")
            scale = fit_scale(kept, inner_w, box_h)
        if not scale:
            continue
        x0 = margin + (inner_w - text_width_cols(kept) * scale) // 2
        y0 = y_top + (box_h - _GLYPH_H * scale) // 2
        _draw_text(canvas, kept, x0, y0, scale)
    return canvas


def _size(value):
    m = re.fullmatch(r"(\d+)[xX](\d+)", value)
    if not m:
        raise argparse.ArgumentTypeError(
            f"{value!r} is not a size. Use WIDTHxHEIGHT in pixels, for example {DEFAULT_SIZE}"
        )
    width, height = int(m.group(1)), int(m.group(2))
    if min(width, height) < MIN_SIDE or max(width, height) > MAX_SIDE or width * height > MAX_PIXELS:
        raise argparse.ArgumentTypeError(
            f"{value!r} is out of range: each side must be {MIN_SIDE} to {MAX_SIDE} pixels "
            f"and the image at most {MAX_PIXELS} pixels in all"
        )
    return width, height


def _dpi(value):
    try:
        dpi = int(value)
    except ValueError:
        dpi = 0
    if not 72 <= dpi <= 1200:
        raise argparse.ArgumentTypeError(f"{value!r} is not a resolution from 72 to 1200 dpi")
    return dpi


def main(argv=None):
    ap = argparse.ArgumentParser(description="Render a two-line text label to an 8-bit grayscale PNG.")
    ap.add_argument("--out", required=True, help="output PNG path")
    ap.add_argument("--size", type=_size, default=_size(DEFAULT_SIZE),
                    help=f"WIDTHxHEIGHT in pixels (default {DEFAULT_SIZE})")
    ap.add_argument("--dpi", type=_dpi, default=DEFAULT_DPI,
                    help=f"resolution recorded in the pHYs chunk (default {DEFAULT_DPI})")
    ap.add_argument("--line1", default="PEEL TEST", help="first (larger) line of text")
    ap.add_argument("--line2", default="", help="second line of text")
    args = ap.parse_args(argv)

    width, height = args.size
    notes = []
    canvas = render(width, height, args.line1, args.line2, notes)
    for note in notes:
        print(f"make-test-png: {note}", file=sys.stderr)
    try:
        with open(args.out, "wb") as fh:
            fh.write(encode_png(width, height, canvas, args.dpi))
    except OSError as err:
        sys.exit(f"make-test-png: cannot write {args.out!r}: {err.strerror}. Check the path and its permissions.")


if __name__ == "__main__":
    main()
