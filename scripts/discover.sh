#!/usr/bin/env bash
# Print the facts peel looks up instead of hardcoding: the LPrint version, the drivers and USB
# devices it sees, what it paired the attached DYMO printer with, the printer queues, the
# configured printer's options and media, the effective server port, and the printer's real IPP
# URI (read from the server, not assumed). Read-only.
#
#   ./scripts/discover.sh        # re-runs itself under sudo
#
# Output formats parsed here were captured from lprint 1.3.1 on a Raspberry Pi 3B (see
# tests/fixtures/). Nothing here has been run against another LPrint version.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

load_config
require_root "$SCRIPT_DIR/discover.sh" "$@"
find_lprint || die "lprint is not installed. Run ./setup.sh first."
LPRINT_SOURCE="$(detect_lprint_source)"

SERVICE=lprint.service
[[ $LPRINT_SOURCE != snap ]] || SERVICE="$(systemctl list-unit-files --no-legend "snap.${SNAP_NAME}.*.service" 2>/dev/null | awk 'NR == 1 { print $1 }')"

ports="$(ss -Hltnp 2>/dev/null | listen_ports_from_ss lprint || true)"
if [[ -z $ports ]]; then
  die "No lprint process is listening. Is the server running? Check: systemctl status ${SERVICE:-lprint.service}, then re-run ./setup.sh"
fi
port="$(head -n1 <<<"$ports")"

info "lprint"
echo "binary:   $LPRINT (installed via $LPRINT_SOURCE)"
echo "version:  $(lprint_cli --version 2>&1 | head -n1)"

info "Drivers LPrint lists for DYMO ('lprint drivers')"
drivers_out="$(lprint_cli drivers 2>&1)" || die "'lprint drivers' failed:
$drivers_out"
parse_driver_names <<<"$drivers_out" | grep -i dymo || echo "(none)"

info "Attached DYMO devices and the driver LPrint pairs with each ('lprint drivers')"
attached="$(parse_attached_dymo <<<"$drivers_out")"
if [[ -n $attached ]]; then
  printf '%s\n' "$attached" | sed 's/^/driver, device:  /'
else
  echo "(none attached)"
fi

info "Devices ('lprint devices')"
devices_out="$(lprint_cli devices 2>&1)" || die "'lprint devices' failed:
$devices_out"
echo "${devices_out:-(none)}"

info "Printer queues ('lprint printers')"
printers_out="$(lprint_cli printers 2>&1)" || die "'lprint printers' failed:
$printers_out"
echo "${printers_out:-(none)}"

info "Options and media for '$PRINTER_NAME' ('lprint options -d $PRINTER_NAME')"
if options_out="$(lprint_cli options -d "$PRINTER_NAME" 2>&1)"; then
  echo "$options_out"
else
  echo "(no printer '$PRINTER_NAME' on the server: $options_out)"
  echo "Run ./setup.sh to add it, or set PRINTER_NAME in config.env to one of the queues above."
fi

info "Server"
echo "port:     $port$([[ $port == "$LISTEN_PORT" ]] && echo ' (matches LISTEN_PORT)' || echo " (LISTEN_PORT is $LISTEN_PORT)")"
echo "web UI:   http://$PRINTER_HOSTNAME.local:$port/"
# /ipp/print/<name> is the path observed on the Pi; it is only used to reach the printer for this
# query. The IPP URI printed below is read from printer-uri-supported, not built from it.
if attrs="$(python3 -I "$SCRIPT_DIR/ipp-attrs.py" "http://localhost:$port/ipp/print/$PRINTER_NAME" \
  printer-name printer-uri-supported media-default media-ready printer-state printer-state-reasons 2>&1)"; then
  for key in printer-name printer-state printer-state-reasons media-default media-ready; do
    value="$(ipp_attr "$key" <<<"$attrs" | paste -sd, -)"
    [[ $key != printer-state ]] || value="$value ($(ipp_state_name "$value"))"
    printf '%-15s %s\n' "${key#printer-}:" "$value"
  done
  # The scheme://host:port part is whatever the request used; only the path is the printer's.
  while IFS= read -r uri; do
    echo "IPP URI:  ${uri%%://*}://$PRINTER_HOSTNAME.local:$port/${uri#*://*/}   (path read from printer-uri-supported)"
  done < <(ipp_attr printer-uri-supported <<<"$attrs")
else
  echo "IPP:      could not read '$PRINTER_NAME' from the server ($attrs)"
fi
