#!/usr/bin/env bash
# scripts/make-test-png.py: PNG structure, text scaling, size validation, unsupported characters.
# No hardware and no lprint: this checks the image peel itself generates, not how the printer
# prints it (that is the hand-run test print).
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required for these tests"
  finish
  exit
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
MAKE="$PEEL_ROOT/scripts/make-test-png.py"

# png_info FILE: decode a PNG with the standard library and print key=value facts. Checks the
# signature, every chunk CRC, the chunk order, that the decompressed data is exactly one filter
# byte plus WIDTH pixels per row, and where the ink is. "ring" is 1 when the band between the
# border and the text margin is entirely white; ink_* is the bounding box of everything inside
# the border.
png_info() {
  python3 -I - "$1" <<'PY'
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
print("signature_ok=%d" % (data[:8] == b"\x89PNG\r\n\x1a\n"))
pos, chunks, crc_ok, idat = 8, [], 1, b""
while pos < len(data):
    n, tag = struct.unpack(">I4s", data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + n]
    (crc,) = struct.unpack(">I", data[pos + 8 + n:pos + 12 + n])
    crc_ok &= int(crc == zlib.crc32(tag + body) & 0xFFFFFFFF)
    chunks.append(tag.decode())
    if tag == b"IHDR":
        w, h, depth, ctype, comp, filt, inter = struct.unpack(">IIBBBBB", body)
        print("width=%d\nheight=%d\nbit_depth=%d\ncolor_type=%d\ninterlace=%d" % (w, h, depth, ctype, inter))
    elif tag == b"pHYs":
        px, py, unit = struct.unpack(">IIB", body)
        print("phys=%d,%d,%d" % (px, py, unit))
    elif tag == b"IDAT":
        idat += body
    pos += 12 + n
print("chunks=%s" % ",".join(chunks))
print("crc_ok=%d" % crc_ok)
raw = zlib.decompress(idat)
print("data_len_ok=%d" % (len(raw) == h * (w + 1)))
rows = [raw[y * (w + 1) + 1:(y + 1) * (w + 1)] for y in range(h)]
print("filters_zero=%d" % all(raw[y * (w + 1)] == 0 for y in range(h)))
border, margin = 6, max(min(w, h) // 10, 18)
xs, ys, ring = [], [], 1
for y in range(h):
    for x in range(w):
        v = rows[y][x]
        d = min(x, y, w - 1 - x, h - 1 - y)
        if d < border:
            if v != 0: ring = 0  # the border itself must be solid black
        elif v == 0:
            xs.append(x); ys.append(y)
            if d < margin: ring = 0
        elif v != 255:
            ring = 0
print("ring=%d" % ring)
if xs:
    print("ink_x=%d,%d\nink_y=%d,%d\nink_w=%d\nink_h=%d" % (min(xs), max(xs), min(ys), max(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1))
else:
    print("ink_w=0\nink_h=0")
PY
}
# field INFO KEY
field() { sed -n "s/^$2=//p" <<<"$1"; }

# --- a default render is a valid 8-bit grayscale PNG with the requested dimensions -----------
out="$tmp/a.png"
python3 -I "$MAKE" --out "$out" --line1 "PEEL TEST" --line2 "labels 2026-10-31" 2>"$tmp/err"
assert_eq "default render exits 0" "0" "$?"
assert_eq "default render prints nothing on stderr" "" "$(<"$tmp/err")"
info="$(png_info "$out")"
assert_eq "PNG signature" "1" "$(field "$info" signature_ok)"
assert_eq "default width (1050)" "1050" "$(field "$info" width)"
assert_eq "default height (330)" "330" "$(field "$info" height)"
assert_eq "8-bit" "8" "$(field "$info" bit_depth)"
assert_eq "grayscale (color type 0)" "0" "$(field "$info" color_type)"
assert_eq "not interlaced" "0" "$(field "$info" interlace)"
assert_eq "chunks IHDR, pHYs, IDAT, IEND in order" "IHDR,pHYs,IDAT,IEND" "$(field "$info" chunks)"
assert_eq "every chunk CRC is valid" "1" "$(field "$info" crc_ok)"
assert_eq "pixel data is exactly height x (1 filter byte + width)" "1" "$(field "$info" data_len_ok)"
assert_eq "pHYs is 300 dpi in pixels per metre (11811), unit metre" "11811,11811,1" "$(field "$info" phys)"
assert_true "there is text ink" test "$(field "$info" ink_w)" -gt 0
assert_eq "border solid, margin band white" "1" "$(field "$info" ring)"

# --- the requested size is honoured, and --dpi changes the pHYs chunk -------------------------
python3 -I "$MAKE" --out "$tmp/b.png" --size 900x300 --dpi 203 --line1 "HELLO"
info="$(png_info "$tmp/b.png")"
assert_eq "custom size: width x height" "900x300" "$(field "$info" width)x$(field "$info" height)"
assert_eq "custom size: PNG data consistent" "1" "$(field "$info" data_len_ok)"
assert_eq "--dpi 203 gives 7992 pixels per metre" "7992,7992,1" "$(field "$info" phys)"
python3 -I "$MAKE" --out "$tmp/c.png" --size 1050X330 --line1 "UPPER-CASE X"
assert_eq "an uppercase X in the size is accepted" "1050x330" "$(field "$(png_info "$tmp/c.png")" width)x$(field "$(png_info "$tmp/c.png")" height)"

# --- the output is deterministic ----------------------------------------------------------------
python3 -I "$MAKE" --out "$tmp/a2.png" --line1 "PEEL TEST" --line2 "labels 2026-10-31"
assert_true "same arguments give the same bytes" cmp -s "$tmp/a.png" "$tmp/a2.png"

# --- text scales to fit -------------------------------------------------------------------------
# E has ink on its first and last row, so the ink height of a line of E's is 7 x scale.
inner_w=$((1050 - 2 * 33))
short="$(python3 -I "$MAKE" --out "$tmp/s.png" --line1 "EE" && png_info "$tmp/s.png")"
long="$(python3 -I "$MAKE" --out "$tmp/l.png" --line1 "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE" && png_info "$tmp/l.png")"
assert_true "short text is drawn larger than long text" test "$(field "$short" ink_h)" -gt "$(field "$long" ink_h)"
assert_true "long text still fits inside the margins (width)" test "$(field "$long" ink_w)" -le "$inner_w"
assert_eq "long text keeps the margin band white" "1" "$(field "$long" ring)"
assert_eq "short text keeps the margin band white" "1" "$(field "$short" ring)"
assert_true "long text is still visible" test "$(field "$long" ink_h)" -ge 7
# A line too long even at the smallest scale is cut, with a note, and the image stays valid.
python3 -I "$MAKE" --out "$tmp/x.png" --line1 "$(printf 'E%.0s' {1..300})" 2>"$tmp/err"
assert_eq "an over-long line still exits 0" "0" "$?"
assert_true "an over-long line is reported as cut" grep -q 'too long.*cut to' "$tmp/err"
info="$(png_info "$tmp/x.png")"
assert_eq "an over-long line leaves a valid PNG of the right size" "1,1050" "$(field "$info" data_len_ok),$(field "$info" width)"
assert_eq "an over-long line stays inside the margins" "1" "$(field "$info" ring)"
# Scaling holds across shapes, including the smallest size and extreme aspect ratios.
for size in 64x64 100x64 64x200 2000x64 64x2000 300x300 1050x330 2400x1200; do
  python3 -I "$MAKE" --out "$tmp/z.png" --size "$size" --line1 "PEEL TEST OF A LONG LINE" --line2 "labels 2026-10-31 and more" 2>/dev/null
  rc=$?
  info="$(png_info "$tmp/z.png")"
  assert_eq "$size: renders, valid data, text inside the margins" "0,$size,1,1,1" \
    "$rc,$(field "$info" width)x$(field "$info" height),$(field "$info" data_len_ok),$(field "$info" crc_ok),$(field "$info" ring)"
  assert_true "$size: some text is drawn" test "$(field "$info" ink_w)" -gt 0
done

# --- unsupported characters are skipped ------------------------------------------------------
python3 -I "$MAKE" --out "$tmp/ab.png" --line1 "AB" --line2 "X-1"
python3 -I "$MAKE" --out "$tmp/skip.png" --line1 "A~B" --line2 "X-1" 2>"$tmp/err"
assert_eq "skipping exits 0" "0" "$?"
assert_true "an unsupported character leaves no gap or mark: same image as without it" cmp -s "$tmp/ab.png" "$tmp/skip.png"
assert_true "the skipped character is named on stderr" grep -q "line 1: skipped unsupported character(s) '~'" "$tmp/err"
python3 -I "$MAKE" --out "$tmp/uni.png" --line1 "AB" --line2 "X-1é€漢" 2>"$tmp/err"
assert_true "non-ASCII characters are skipped, not drawn" cmp -s "$tmp/ab.png" "$tmp/uni.png"
assert_true "non-ASCII skips are reported for line 2" grep -q 'line 2: skipped' "$tmp/err"
python3 -I "$MAKE" --out "$tmp/lower.png" --line1 "ab" --line2 "x-1"
assert_true "lowercase is drawn as uppercase" cmp -s "$tmp/ab.png" "$tmp/lower.png"
python3 -I "$MAKE" --out "$tmp/none.png" --line1 "~~~" --line2 "" 2>"$tmp/err"
assert_eq "a line with only unsupported characters still exits 0" "0" "$?"
python3 -I "$MAKE" --out "$tmp/blank.png" --line1 "" --line2 ""
assert_true "such a line draws nothing, like an empty one (border only)" cmp -s "$tmp/none.png" "$tmp/blank.png"
assert_eq "an empty label is a valid PNG with no text ink" "1,0" \
  "$(field "$(png_info "$tmp/blank.png")" data_len_ok),$(field "$(png_info "$tmp/blank.png")" ink_w)"
for ch in A Z 0 9 ' ' - : . /; do
  python3 -I "$MAKE" --out "$tmp/g.png" --line1 "$ch" 2>"$tmp/err"
  assert_eq "supported character '$ch' is accepted without a note" "0,0" "$?,$(wc -c <"$tmp/err" | tr -d ' ')"
done

# --- a bad --size fails with a clear error and writes nothing -------------------------------
for bad in 10x10 abc 1050 1050x x330 0x0 -5x100 63x300 300x63 10001x100 5000x5000 "1050 x 330" 1.5x2 ""; do
  rm -f "$tmp/bad.png"
  python3 -I "$MAKE" --out "$tmp/bad.png" --size "$bad" --line1 X 2>"$tmp/err"
  rc=$?
  assert_eq "--size '$bad' exits non-zero" "2" "$rc"
  assert_true "--size '$bad' error names --size and says what to use" grep -Eq -- '--size.*(not a size|out of range)' "$tmp/err"
  assert_false "--size '$bad' writes no file" test -e "$tmp/bad.png"
done
python3 -I "$MAKE" --out "$tmp/bad.png" --size abc 2>"$tmp/err"
assert_true "the error shows an example size" grep -q 'WIDTHxHEIGHT in pixels, for example 1050x330' "$tmp/err"
python3 -I "$MAKE" --out "$tmp/bad.png" --size 10x10 2>"$tmp/err"
assert_true "an out-of-range size states the allowed range" grep -q 'each side must be 64 to 10000 pixels' "$tmp/err"
for bad in 0 71 1201 abc 3.5; do
  python3 -I "$MAKE" --out "$tmp/bad.png" --dpi "$bad" 2>"$tmp/err"
  assert_eq "--dpi '$bad' exits non-zero" "2" "$?"
done
python3 -I "$MAKE" --out "$tmp/no-such-dir/x.png" 2>"$tmp/err"
assert_eq "an unwritable --out exits non-zero" "1" "$?"
assert_true "an unwritable --out says what to check" grep -q 'cannot write.*Check the path' "$tmp/err"
python3 -I "$MAKE" --size 100x100 2>"$tmp/err"
assert_eq "a missing --out exits non-zero" "2" "$?"

finish
