#!/usr/bin/env bash
# scripts/test-print.sh without hardware: DRY_RUN renders the label and shows the submit command,
# and never calls lprint. Printing itself (`lprint submit`) is verified by hand on the Pi; there
# is deliberately no stub lprint here, because a stub would only encode guesses about its output.
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
SCRIPT="$PEEL_ROOT/scripts/test-print.sh"

# A config that is not the example's, so a hardcoded printer name or hostname would show.
cat >"$tmp/config.env" <<'CFG'
PRINTER_NAME="MY_TEST_PRINTER"
PRINTER_HOSTNAME="shelf"
CFG

# A tripwire lprint first on PATH: DRY_RUN must never run it.
mkdir "$tmp/bin"
printf '#!/bin/sh\ntouch "%s/lprint-was-run"\n' "$tmp" >"$tmp/bin/lprint"
chmod +x "$tmp/bin/lprint"

# dry [ENV=VALUE...] -- ARGS...: run the script in DRY_RUN against the temp config; sets $out, $rc.
dry() {
  local envs=()
  while [[ ${1:-} != -- ]]; do envs+=("$1"); shift; done
  shift
  out="$(env -u TEST_PNG_SIZE "${envs[@]}" DRY_RUN=1 CONFIG_FILE="$tmp/config.env" PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$@" 2>&1)"
  rc=$?
}

dry --
assert_eq "dry run exits 0" "0" "$rc"
assert_true "dry run renders at the default 1050x330" grep -qF 'Rendering test label (1050x330 px)' <<<"$out"
assert_true "dry run shows the submit command with the configured printer name" grep -qE 'lprint submit -d MY_TEST_PRINTER /.*/test\.png' <<<"$out"
assert_false "no printer name is hardcoded in the output" grep -qF DYMO_LabelWriter <<<"$out"
assert_false "dry run did not run lprint" test -e "$tmp/lprint-was-run"

dry -- "HELLO WORLD"
assert_eq "custom text exits 0" "0" "$rc"
assert_false "custom text raises no complaint" grep -q 'skipped' <<<"$out"
dry -- "HELLO ~ WORLD"
assert_eq "text with an unsupported character still exits 0" "0" "$rc"
assert_true "the skipped character is reported" grep -qF "skipped unsupported character(s) '~'" <<<"$out"
dry -- ""
assert_eq "an empty text argument exits 0" "0" "$rc"

dry TEST_PNG_SIZE=900x300 --
assert_eq "a non-default TEST_PNG_SIZE exits 0" "0" "$rc"
assert_true "a non-default TEST_PNG_SIZE is used" grep -qF 'Rendering test label (900x300 px)' <<<"$out"
dry TEST_PNG_SIZE=600x200 -- "TWO WORDS"
assert_eq "custom text and a custom size together exit 0" "0" "$rc"
assert_true "both are used" grep -qF 'Rendering test label (600x200 px)' <<<"$out"

for bad in abc 1050 1050x x330 -1x100 "1050 330" 1.5x2; do
  dry TEST_PNG_SIZE="$bad" --
  assert_true "TEST_PNG_SIZE='$bad' fails" test "$rc" -ne 0
  assert_true "TEST_PNG_SIZE='$bad' error names TEST_PNG_SIZE and an example" grep -qF "TEST_PNG_SIZE='$bad' must look like 1050x330" <<<"$out"
done
for bad in 10x10 63x300 99999x99999; do
  dry TEST_PNG_SIZE="$bad" --
  assert_true "TEST_PNG_SIZE=$bad (out of range) fails" test "$rc" -ne 0
  assert_true "TEST_PNG_SIZE=$bad error says what to fix" grep -qF 'fix TEST_PNG_SIZE' <<<"$out"
  assert_false "TEST_PNG_SIZE=$bad does not submit anything" grep -qF 'would run' <<<"$out"
done

dry -- one two
assert_true "two arguments are refused" test "$rc" -ne 0
assert_true "the refusal says to quote the text" grep -qF 'quote it' <<<"$out"

out="$(bash "$SCRIPT" --help 2>&1)"
assert_eq "--help exits 0" "0" "$?"
assert_true "--help shows the usage" grep -qF 'TEST_PNG_SIZE' <<<"$out"

# config.env can supply TEST_PNG_SIZE too, and a missing config fails with the fix to run.
printf 'TEST_PNG_SIZE=800x250\n' >>"$tmp/config.env"
dry --
assert_true "TEST_PNG_SIZE from config.env is used" grep -qF 'Rendering test label (800x250 px)' <<<"$out"

# --- the repository no longer suggests an undocumented LPrint option --------------------------
cd "$PEEL_ROOT" || exit 1
hits="$(grep -rIl 'print-scaling' README.md setup.sh config.env.example scripts systemd 2>/dev/null || true)"
assert_eq "no print-scaling suggestion in the product files or README" "" "$hits"
assert_false "test-print.sh hardcodes no printer name" grep -q 'DYMO_LabelWriter' scripts/test-print.sh
assert_false "test-print.sh passes lprint submit no -o options (none are confirmed on the Pi)" grep -Eq 'submit .*-o ' scripts/test-print.sh

finish
