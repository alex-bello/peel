#!/usr/bin/env bash
# Print a simple text test label through the local LPrint server.
#
#   sudo ./scripts/test-print.sh                  # first line "PEEL TEST", second "<hostname> <date>"
#   sudo ./scripts/test-print.sh "HELLO WORLD"    # custom first line
#   sudo TEST_PNG_SIZE=900x300 ./scripts/test-print.sh   # image size in pixels, WIDTHxHEIGHT
#   DRY_RUN=1 ./scripts/test-print.sh             # render and show the submit command; print nothing
#
# LPrint has no text renderer, so this draws the text into a PNG (scripts/make-test-png.py,
# standard-library Python) and submits that with `lprint submit -d <printer> <file>`. The
# printer is PRINTER_NAME from config.env. Letters are A-Z (lowercase is drawn as uppercase),
# digits, space and - : . / ; other characters are skipped with a note.
#
# TEST_PNG_SIZE (environment, or set in config.env) defaults to 1050x330: 3.5 x 1.1 inches at
# 300 dpi. That matches the default media on the test Pi, oe_address-label_1.125x3.5in, and
# `printer-resolution=300dpi` (both OBSERVED in `lprint options`, lprint 1.3.1). It is a
# starting point, not a verified fit: whether LPrint scales, rotates or crops this image on the
# 450 Turbo is UNVERIFIED until the hand-run print. This script passes `lprint submit` no
# options; none are documented as confirmed on the Pi for scaling or orientation.
#
# UNVERIFIED on hardware: everything this script does with `lprint submit` (that the CLI
# accepts a PNG this way, how it reports success, how the label comes out). The CLI is run the
# way setup.sh runs it, as the service user (OBSERVED to work for the other subcommands; as
# root `lprint` failed on the test Pi).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

case ${1:-} in
  -h | --help)
    sed -n '2,/^set -Eeuo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
    exit 0
    ;;
esac
if (($# > 1)); then
  die "Takes at most one argument, the first line of text (quote it if it has spaces). Got $# arguments."
fi

require_root "$SCRIPT_DIR/test-print.sh" "$@"
load_config

text="${1:-PEEL TEST}"
size="${TEST_PNG_SIZE:-1050x330}"
[[ $size =~ ^[0-9]+x[0-9]+$ ]] \
  || die "TEST_PNG_SIZE='$size' must look like 1050x330 (WIDTHxHEIGHT in pixels). Fix or unset it, then re-run."

command -v python3 >/dev/null 2>&1 || die "python3 not found. Install it with: sudo apt-get install python3 (it ships with Raspberry Pi OS)."

if find_lprint; then
  LPRINT_SOURCE="$(detect_lprint_source)"
elif [[ $DRY_RUN == 1 ]]; then
  warn "lprint is not installed here; the dry run still renders the label."
  LPRINT=lprint LPRINT_SOURCE=''
else
  die "lprint is not installed. Run ./setup.sh first."
fi

# The PNG is read by the lprint CLI, which runs as the service user, not as root: make the
# directory and file world-readable (the label holds only the text above).
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
chmod 0755 "$tmpdir"
png="$tmpdir/test.png"

info "Rendering test label ($size px)"
python3 -I "$SCRIPT_DIR/make-test-png.py" --out "$png" --size "$size" \
  --line1 "$text" --line2 "$PRINTER_HOSTNAME $(date +%F)" \
  || die "Could not render the test label (message above). If it names the size, fix TEST_PNG_SIZE (WIDTHxHEIGHT in pixels, for example 1050x330) and re-run."
chmod 0644 "$png"

if [[ $DRY_RUN == 1 ]]; then
  info "[dry-run] would run: lprint submit -d $PRINTER_NAME $png   (as the service user on apt installs)"
  exit 0
fi

queues="$(lprint_cli printers | parse_printer_queue_names)" \
  || die "'lprint printers' failed (message above). Is the server running? Check: systemctl status lprint, then re-run ./setup.sh"
grep -qFx -- "$PRINTER_NAME" <<<"$queues" \
  || die "No printer '$PRINTER_NAME' on the LPrint server. Run ./setup.sh to add it, or set PRINTER_NAME in config.env to one of the queues that ./scripts/discover.sh lists."

info "Submitting to '$PRINTER_NAME'"
lprint_cli submit -d "$PRINTER_NAME" "$png" \
  || die "'lprint submit -d $PRINTER_NAME' failed (message above). Check the server and printer with ./scripts/discover.sh and: journalctl -u lprint -b --no-pager"

ok "Submitted (the command above exited 0; that is not proof of a printed label). If nothing printed, run ./scripts/discover.sh and look at the printer state and reasons, and the server log: journalctl -u lprint -b --no-pager"
