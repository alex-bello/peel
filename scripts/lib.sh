#!/usr/bin/env bash
# Shared helpers for the peel scripts. Source this file; do not execute it.
# shellcheck shell=bash

PEEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN="${DRY_RUN:-0}"

if [[ -t 1 && -t 2 ]]; then
  C_RED=$'\e[31m' C_YEL=$'\e[33m' C_GRN=$'\e[32m' C_BLU=$'\e[34m' C_OFF=$'\e[0m'
else
  C_RED='' C_YEL='' C_GRN='' C_BLU='' C_OFF=''
fi

info() { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s ok%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

on_err() {
  printf '%sFAIL%s %s: line %s: %s\n' "$C_RED" "$C_OFF" "${0##*/}" "$1" "$2" >&2
}

# run CMD...: execute, or just print it when DRY_RUN=1.
run() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '%s[dry-run]%s %s\n' "$C_YEL" "$C_OFF" "$*"
    return 0
  fi
  "$@"
}

# Re-exec under sudo when not root. DRY_RUN needs no privileges, so it never escalates.
# Call as: require_root "$@"
require_root() {
  [[ $DRY_RUN == 1 || $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || die "Must run as root and sudo is not installed."
  info "Re-running under sudo"
  exec sudo -E "$0" "$@"
}

# Source config.env (or, for DRY_RUN only, config.env.example) and apply defaults.
load_config() {
  local cfg="${CONFIG_FILE:-$PEEL_ROOT/config.env}"
  if [[ ! -f $cfg ]]; then
    if [[ $DRY_RUN == 1 ]]; then
      warn "$cfg not found; using config.env.example for this dry run"
      cfg="$PEEL_ROOT/config.env.example"
    else
      die "$cfg not found. Create it with: cp config.env.example config.env"
    fi
  fi
  # shellcheck source=/dev/null
  source "$cfg"

  : "${PRINTER_NAME:=DYMO_450_Turbo}"
  : "${PRINTER_HOSTNAME:=labels}"
  : "${DRIVER:=}"
  : "${DEVICE_URI:=}"
  : "${MEDIA_READY:=}"
  : "${PRINTER_OPTIONS:=}"
  : "${INSTALL_METHOD:=auto}"
  : "${SNAP_NAME:=lprint}"
  : "${LISTEN_PORT:=}"
  : "${SERVER_OPTIONS:=}"

  # The name ends up in the IPP URL path, so keep it URL-safe.
  [[ $PRINTER_NAME =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "PRINTER_NAME='$PRINTER_NAME' may only contain letters, digits, '_' and '-'."
  [[ $PRINTER_HOSTNAME =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
    || die "PRINTER_HOSTNAME='$PRINTER_HOSTNAME' must be a lowercase DNS label (a-z, 0-9, '-')."
  [[ $INSTALL_METHOD =~ ^(auto|apt|snap)$ ]] \
    || die "INSTALL_METHOD='$INSTALL_METHOD' must be auto, apt or snap."
  [[ -z $LISTEN_PORT || $LISTEN_PORT =~ ^[0-9]+$ ]] \
    || die "LISTEN_PORT='$LISTEN_PORT' must be empty or a number."
}

# count_lines TEXT: number of non-empty-text lines (0 for empty text). Avoids
# `grep -c`, whose exit status 1 on zero matches would fire the ERR trap.
count_lines() {
  if [[ -z $1 ]]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}

# Set LPRINT to the lprint binary. Returns 1 if it is not installed.
# /snap/bin is checked explicitly because sudo's secure_path often omits it.
find_lprint() {
  if LPRINT="$(command -v lprint 2>/dev/null)" && [[ -n $LPRINT ]]; then
    return 0
  fi
  if [[ -x /snap/bin/lprint ]]; then
    LPRINT=/snap/bin/lprint
    return 0
  fi
  LPRINT=''
  return 1
}

# Print the TCP port(s) the lprint server is listening on, one per line.
# Needs root to see other users' sockets.
listen_ports() {
  ss -Hltnp 2>/dev/null | awk '/"lprint"/ { n = split($4, a, ":"); print a[n] }' | sort -un
}
