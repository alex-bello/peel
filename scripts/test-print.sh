#!/usr/bin/env bash
# Print a simple text test label through the local LPrint server.
#
#   sudo ./scripts/test-print.sh                 # prints "PEEL TEST" + hostname/date
#   sudo ./scripts/test-print.sh "HELLO WORLD"   # custom first line
#   TEST_PNG_SIZE=1050x330 sudo -E ./scripts/test-print.sh   # override image size in pixels
#
# LPrint has no text renderer, so this draws the text into a PNG (stdlib-only
# Python) and submits that. Letters are A-Z, digits and - : . /; others are skipped.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

require_root "$@"
load_config
find_lprint || die "lprint is not installed. Run ./setup.sh first."
command -v python3 >/dev/null 2>&1 || die "python3 not found (it ships with Raspberry Pi OS)."

text="${1:-PEEL TEST}"
size="${TEST_PNG_SIZE:-1050x330}" # 3.5 x 1.1 in at 300 dpi, the common 30252 address label

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
png="$tmpdir/test.png"

info "Rendering test label ($size px)"
python3 -I "$SCRIPT_DIR/make-test-png.py" --out "$png" --size "$size" \
  --line1 "$text" --line2 "$PRINTER_HOSTNAME $(date +%F)"

info "Submitting to '$PRINTER_NAME'"
"$LPRINT" submit -d "$PRINTER_NAME" "$png"

ok "Submitted. If nothing prints, check the job state in the Web UI (see ./scripts/discover.sh for its URL)."
