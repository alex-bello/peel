#!/usr/bin/env bash
# Server options, systemd unit and udev rule rendering, idempotent file writes, and ss
# parsing (scripts/lib.sh, systemd/lprint.service). No hardware needed, and no stub lprint:
# these check what peel itself generates, not what LPrint prints.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/lib.sh
source "$PEEL_ROOT/scripts/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- build_server_options ---------------------------------------------------
LISTEN_PORT=8631 SERVER_OPTIONS=''
assert_eq "default server options" \
  "-o server-port=8631 -o spool-directory=/var/spool/lprint -o log-file=-" \
  "$(build_server_options)"
LISTEN_PORT=9100 SERVER_OPTIONS='-o log-level=debug'
assert_eq "custom port and extra options" \
  "-o server-port=9100 -o spool-directory=/var/spool/lprint -o log-file=- -o log-level=debug" \
  "$(build_server_options)"

# --- render_unit ------------------------------------------------------------
LISTEN_PORT=8631 SERVER_OPTIONS=''
unit="$(render_unit "$PEEL_ROOT/systemd/lprint.service" /usr/bin/lprint)"
for want in \
  "User=lprint" \
  "Group=lprint" \
  "Type=simple" \
  "NoNewPrivileges=yes" \
  "StateDirectory=lprint" \
  "StateDirectoryMode=0750" \
  "Environment=HOME=/var/lib/lprint" \
  "Requires=avahi-daemon.socket" \
  "ExecStart=/usr/bin/lprint server -o server-port=8631 -o spool-directory=/var/spool/lprint -o log-file=-" \
  "Restart=on-failure" \
  "WantedBy=multi-user.target"; do
  if grep -qxF -- "$want" <<<"$unit"; then pass "unit has: $want"; else fail "unit has: $want"; fi
done
assert_false "no unfilled @placeholders@ remain" grep -qE '@[A-Z_]+@' <<<"$unit"
assert_false "unit has no PrivateTmp (it would hide the CLI socket /tmp/lprint<uid>.sock)" grep -qi '^PrivateTmp' <<<"$unit"
assert_eq "StateDirectory name matches the HOME directory" "/var/lib/lprint" "/var/lib/$STATE_NAME"
assert_false "unit never uses the wrong option name" grep -q 'listen-port' <<<"$unit"
assert_eq "render_unit is deterministic" "$unit" "$(render_unit "$PEEL_ROOT/systemd/lprint.service" /usr/bin/lprint)"
LISTEN_PORT=9100
assert_true "unit follows LISTEN_PORT" grep -qF 'server-port=9100' <<<"$(render_unit "$PEEL_ROOT/systemd/lprint.service" /snap/bin/lprint)"

# --- render_udev_rule -------------------------------------------------------
rule="$(render_udev_rule)"
assert_true "udev rule matches DYMO vendor 0922" grep -qF 'ATTR{idVendor}=="0922"' <<<"$rule"
assert_true "udev rule grants group lprint" grep -qF 'GROUP="lprint"' <<<"$rule"
assert_true "udev rule sets mode 0660" grep -qF 'MODE="0660"' <<<"$rule"

# --- write_if_changed (real writes into a temp dir) ------------------------
f="$tmp/out.conf"
DRY_RUN=0
write_if_changed "$f" "hello" 644 >/dev/null 2>&1
assert_eq "first write returns 0 and creates the file" "0:hello" "$?:$(<"$f")"
write_if_changed "$f" "hello" 644 >/dev/null 2>&1
assert_eq "identical rewrite reports unchanged (1)" "1" "$?"
write_if_changed "$f" "changed" 644 >/dev/null 2>&1
assert_eq "different content is rewritten" "0:changed" "$?:$(<"$f")"
DRY_RUN=1
out="$(write_if_changed "$f" "dry" 644)"
assert_eq "DRY_RUN does not modify the file" "changed" "$(<"$f")"
assert_true "DRY_RUN prints what it would write" grep -q 'would write' <<<"$out"
write_if_changed "$tmp/new.conf" "x" 644 >/dev/null
assert_false "DRY_RUN does not create new files" test -e "$tmp/new.conf"
DRY_RUN=0

# --- listen_ports_from_ss (stdin is `ss -Hltnp`; column layout is ss's, not LPrint's) ---
ss_out='LISTEN 0 4096 0.0.0.0:8631 0.0.0.0:* users:(("lprint",pid=812,fd=6))
LISTEN 0 4096 [::]:8631 [::]:* users:(("lprint",pid=812,fd=7))
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=401,fd=3))
LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=401,fd=4))'
assert_eq "ports of every listener, unique" $'22\n8631' "$(listen_ports_from_ss <<<"$ss_out")"
assert_eq "ports filtered by process name" "8631" "$(listen_ports_from_ss lprint <<<"$ss_out")"
assert_eq "no match gives no ports" "" "$(listen_ports_from_ss cupsd <<<"$ss_out")"

# --- template and scripts must not carry the corrected-away guesses ---------
for f in setup.sh scripts/lib.sh systemd/lprint.service config.env.example; do
  assert_false "$f: no listen-port option" grep -q 'listen-port' "$PEEL_ROOT/$f"
done

finish
