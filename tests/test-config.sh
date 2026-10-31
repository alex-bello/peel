#!/usr/bin/env bash
# Config defaults and validation (scripts/lib.sh). No hardware needed.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/lib.sh
source "$PEEL_ROOT/scripts/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# cfg_run BODY: load a config.env containing BODY in a subshell; prints "KEY=value" lines on
# success. A die() exits the subshell, so the caller sees a non-zero status.
cfg_run() {
  printf '%s\n' "$1" >"$tmp/config.env"
  (
    DRY_RUN=0
    CONFIG_FILE="$tmp/config.env"
    load_config 2>/dev/null
    printf 'PRINTER_HOSTNAME=%s INSTALL_METHOD=%s SNAP_NAME=%s LISTEN_PORT=%s SERVER_OPTIONS=%s\n' \
      "$PRINTER_HOSTNAME" "$INSTALL_METHOD" "$SNAP_NAME" "$LISTEN_PORT" "$SERVER_OPTIONS"
  )
}

# Defaults: an empty config yields the documented defaults, including the pinned port.
assert_eq "empty config gives defaults" \
  "PRINTER_HOSTNAME=labels INSTALL_METHOD=auto SNAP_NAME=lprint LISTEN_PORT=8631 SERVER_OPTIONS=" \
  "$(cfg_run '')"
assert_eq "empty LISTEN_PORT means the default" "8631" \
  "$(cfg_run 'LISTEN_PORT=""' | sed 's/.*LISTEN_PORT=\([0-9]*\).*/\1/')"
assert_eq "LISTEN_PORT override is kept" "9100" \
  "$(cfg_run 'LISTEN_PORT=9100' | sed 's/.*LISTEN_PORT=\([0-9]*\).*/\1/')"
assert_eq "leading zeros are normalized to decimal" "8631" \
  "$(cfg_run 'LISTEN_PORT=08631' | sed 's/.*LISTEN_PORT=\([0-9]*\).*/\1/')"

# LISTEN_PORT validation (1-65535).
for p in 1 80 8631 65535; do
  assert_true "port $p is valid" is_valid_port "$p"
done
for p in 0 65536 99999 -1 abc 80a '8 0' ''; do
  assert_false "port '$p' is invalid" is_valid_port "$p"
  if [[ -n $p ]]; then   # an empty LISTEN_PORT is not an error; it means the default (tested above)
    assert_false "config with LISTEN_PORT='$p' is rejected" cfg_run "LISTEN_PORT='$p'"
  fi
done

# Below 1024 the dedicated non-root user cannot bind: rejected unless the snap path is forced.
assert_false "LISTEN_PORT=80 rejected with INSTALL_METHOD=auto" cfg_run 'LISTEN_PORT=80'
assert_false "LISTEN_PORT=80 rejected with INSTALL_METHOD=apt" cfg_run $'INSTALL_METHOD=apt\nLISTEN_PORT=80'
assert_true "LISTEN_PORT=80 accepted with INSTALL_METHOD=snap (ignored there)" cfg_run $'INSTALL_METHOD=snap\nLISTEN_PORT=80'
assert_true "LISTEN_PORT=1024 accepted on the apt path" cfg_run 'LISTEN_PORT=1024'
assert_false "LISTEN_PORT=1023 rejected on the apt path" cfg_run 'LISTEN_PORT=1023'
port_msg() { LISTEN_PORT=80 check_listen_port_bindable; }   # env prefix on a function call is not a subshell
out="$(port_msg 2>&1)"
case $out in
  *"LISTEN_PORT=80"*"config.env"*) pass "privileged-port error names LISTEN_PORT and config.env" ;;
  *) fail "privileged-port error names LISTEN_PORT and config.env" "got: $out" ;;
esac

# The example config must load cleanly and keep the documented pinned default.
(
  DRY_RUN=0 CONFIG_FILE="$PEEL_ROOT/config.env.example"
  load_config >/dev/null 2>&1 && [[ $LISTEN_PORT == 8631 && $PRINTER_HOSTNAME == labels ]]
)
assert_eq "config.env.example loads with LISTEN_PORT 8631" "0" "$?"

# Other keys.
assert_false "uppercase hostname rejected" cfg_run 'PRINTER_HOSTNAME=Labels'
assert_false "hostname with underscore rejected" cfg_run 'PRINTER_HOSTNAME=my_pi'
assert_false "hostname starting with '-' rejected" cfg_run 'PRINTER_HOSTNAME=-pi'
assert_true "hostname 'my-pi-2' accepted" cfg_run 'PRINTER_HOSTNAME=my-pi-2'
assert_false "unknown INSTALL_METHOD rejected" cfg_run 'INSTALL_METHOD=docker'
assert_true "INSTALL_METHOD=snap accepted" cfg_run 'INSTALL_METHOD=snap'
assert_false "bad SNAP_NAME rejected" cfg_run 'SNAP_NAME="Bad Name"'

# SERVER_OPTIONS: plain options pass; systemd-significant characters and a competing
# server-port are rejected.
assert_true "SERVER_OPTIONS '-o log-level=debug' accepted" cfg_run 'SERVER_OPTIONS="-o log-level=debug"'
assert_false "SERVER_OPTIONS with '%' rejected" cfg_run 'SERVER_OPTIONS="-o x=%h"'
# shellcheck disable=SC2016  # the config file must receive a literal dollar sign
assert_false "SERVER_OPTIONS with '\$' rejected" cfg_run 'SERVER_OPTIONS="-o x=\$HOME"'
assert_false "SERVER_OPTIONS with a newline rejected" cfg_run $'SERVER_OPTIONS="-o a=b\nExecStartPost=/bin/true"'
assert_false "SERVER_OPTIONS setting server-port rejected" cfg_run 'SERVER_OPTIONS="-o server-port=1234"'

# Missing config: real runs fail with the cp hint; DRY_RUN falls back to the example.
out="$( (DRY_RUN=0 CONFIG_FILE="$tmp/nope.env"; load_config) 2>&1 || true)"
assert_false "missing config.env fails outside DRY_RUN" bash -c "
  source '$PEEL_ROOT/scripts/lib.sh'; DRY_RUN=0 CONFIG_FILE='$tmp/nope.env'; load_config"
case $out in
  *"cp config.env.example config.env"*) pass "missing config tells the user what to run" ;;
  *) fail "missing config tells the user what to run" "got: $out" ;;
esac
assert_true "DRY_RUN falls back to config.env.example" bash -c "
  source '$PEEL_ROOT/scripts/lib.sh'; DRY_RUN=1 CONFIG_FILE='$tmp/nope.env'; load_config"

finish
