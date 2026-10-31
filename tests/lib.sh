#!/usr/bin/env bash
# Tiny assertion helpers for the peel tests. Source this file; do not execute it.
# Each test file is a standalone process: call `finish` last to print a summary and
# exit non-zero if any check failed. PEEL_ROOT may point at another checkout.
# shellcheck shell=bash

PEEL_ROOT="${PEEL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PEEL_ROOT

_passed=0
_failed=0

pass() { _passed=$((_passed + 1)); printf 'ok   - %s\n' "$1"; }
fail() {
  _failed=$((_failed + 1))
  printf 'FAIL - %s\n' "$1"
  [[ -n ${2:-} ]] && printf '       %s\n' "$2"
  return 0
}

# assert_eq NAME EXPECTED ACTUAL
assert_eq() {
  if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

# assert_true NAME CMD...: passes when CMD exits 0 (output is hidden).
assert_true() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name" "command failed: $*"; fi
}

# assert_false NAME CMD...: passes when CMD exits non-zero.
assert_false() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then fail "$name" "command unexpectedly succeeded: $*"; else pass "$name"; fi
}

# finish: print the summary and exit with the failure status.
finish() {
  printf '%s: %d passed, %d failed\n' "${0##*/}" "$_passed" "$_failed"
  [[ $_failed -eq 0 ]]
}
