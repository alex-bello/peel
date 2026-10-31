#!/usr/bin/env bash
# setup.sh with DRY_RUN=1: exits 0, prints every step, needs no root and no config.env, and
# bad config fails before anything runs. Runs on a copy of the tree so a developer's own
# config.env never leaks in.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/systemd"
cp "$PEEL_ROOT/setup.sh" "$tmp/setup.sh"
cp "$PEEL_ROOT/scripts/lib.sh" "$tmp/scripts/lib.sh"
cp "$PEEL_ROOT/scripts/ipp-attrs.py" "$tmp/scripts/ipp-attrs.py"
cp "$PEEL_ROOT/systemd/lprint.service" "$tmp/systemd/lprint.service"
cp "$PEEL_ROOT/config.env.example" "$tmp/config.env.example"

out="$(DRY_RUN=1 bash "$tmp/setup.sh" 2>&1)"
status=$?
assert_eq "DRY_RUN=1 ./setup.sh exits 0" "0" "$status"

# Every step announces itself.
for step in "Preflight" "Hostname" "Checking that CUPS is absent" "Packages" \
  "Service user" "systemd service" "Enable and start" "Printer 'DYMO_LabelWriter_450_Turbo'"; do
  case $out in
    *"==> $step"*) pass "plan shows step: $step" ;;
    *) fail "plan shows step: $step" ;;
  esac
done
for want in "lprint add -d DYMO_LabelWriter_450_Turbo -m <driver> -v <uri>" "lprint delete -d DYMO_LabelWriter_450_Turbo" \
  "/var/lib/peel/printer.state" "MEDIA_READY is empty: would warn and list the valid media names" \
  "would restart lprint.service only if the printer was added or changed" "server-port=8631" "spool-directory=/var/spool/lprint" "log-file=-" "User=lprint" \
  'idVendor}=="0922"' "Dry run complete; nothing was changed."; do
  case $out in
    *"$want"*) pass "plan mentions: $want" ;;
    *) fail "plan mentions: $want" ;;
  esac
done
assert_true "falls back to config.env.example" grep -q 'config.env.example' <<<"$out"

# Amendment A4: on the apt path peel always installs its own unit, reloads, and restarts only
# when needed. Skipped when this host's plan takes the snap path (no own unit there).
if [[ $out == *"snap path:"* || $out == *"Installing lprint from the snap"* ]]; then
  pass "A4 plan assertions skipped: the plan shows the snap path"
else
  for want in "would write /etc/systemd/system/lprint.service" "NoNewPrivileges=yes" \
    "StateDirectory=lprint" "Environment=HOME=/var/lib/lprint" \
    "systemctl daemon-reload" "systemctl enable lprint.service" \
    "remove /run/lprint.sock if it exists and nothing listens on it"; do
    case $out in
      *"$want"*) pass "plan has own unit step: $want" ;;
      *) fail "plan has own unit step: $want" ;;
    esac
  done
  case $out in
    *"systemctl restart lprint.service"* | *"restart lprint.service only if needed"*) pass "plan restarts the service conditionally or because the unit changed" ;;
    *) fail "plan restarts the service conditionally or because the unit changed" ;;
  esac
  case $out in
    *"No unit shipped"* | *"ships its own unit: lprint.service"*) fail "plan does not rely on a shipped unit" ;;
    *) pass "plan does not rely on a shipped unit" ;;
  esac
fi

# Ordering: read-only refusals (CUPS) come before the hostname mutation.
before() { # before NEEDLE_A NEEDLE_B: A appears earlier than B in $out
  local a=${out%%"$1"*} b=${out%%"$2"*}
  [[ $out == *"$1"* && $out == *"$2"* && ${#a} -lt ${#b} ]]
}
assert_true "CUPS check runs before the hostname change" before "==> Checking that CUPS" "==> Hostname"

# Ordering: apt-get update runs before the lprint package is installed (and before the apt vs
# snap choice). Only checkable when this host would install lprint at all.
if [[ $out == *"Installing lprint from apt"* ]]; then
  assert_true "apt-get update runs before installing lprint" before "apt-get update" "Installing lprint from apt"
  assert_true "lprint is installed without recommends" grep -q 'apt-get install -y --no-install-recommends lprint' <<<"$out"
else
  pass "apt-get update ordering skipped: lprint already installed on this host"
fi

# The plan above only says what would run. step_printer returns before any lprint call in a dry
# run (it would talk to, or start, a server); that is not asserted here, only reviewed.

# MEDIA_READY set: the plan names the value.
cfg="$tmp/media.env"
echo 'MEDIA_READY=oe_shipping-label_2.125x4in' >"$cfg"
out2="$(CONFIG_FILE="$cfg" DRY_RUN=1 bash "$tmp/setup.sh" 2>&1)"
assert_eq "DRY_RUN with MEDIA_READY exits 0" "0" "$?"
case $out2 in
  *"MEDIA_READY=oe_shipping-label_2.125x4in against"*) pass "plan checks the configured MEDIA_READY" ;;
  *) fail "plan checks the configured MEDIA_READY" ;;
esac

# Nothing was created next to the script (no config.env, no state).
assert_false "DRY_RUN created no config.env" test -e "$tmp/config.env"

# Config errors stop the run before any step, even without DRY_RUN and without root.
bad="$tmp/bad.env"
echo 'LISTEN_PORT=70000' >"$bad"
out="$(CONFIG_FILE="$bad" DRY_RUN=0 bash "$tmp/setup.sh" 2>&1)"
assert_eq "invalid LISTEN_PORT exits non-zero" "1" "$?"
case $out in
  *"LISTEN_PORT='70000'"*) pass "error names the bad key and value" ;;
  *) fail "error names the bad key and value" "got: $out" ;;
esac
case $out in
  *"==>"*) fail "no step ran before the config error" "got: $out" ;;
  *) pass "no step ran before the config error" ;;
esac

out="$(CONFIG_FILE="$tmp/missing.env" DRY_RUN=0 bash "$tmp/setup.sh" 2>&1)"
assert_eq "missing config.env exits non-zero" "1" "$?"
case $out in
  *"cp config.env.example config.env"*) pass "missing config.env names the fix" ;;
  *) fail "missing config.env names the fix" "got: $out" ;;
esac

finish
