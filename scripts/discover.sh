#!/usr/bin/env bash
# Print the facts peel discovers instead of hardcoding: lprint version, DYMO
# drivers, USB devices, the configured printer's media options, and the server
# port/URLs. Read-only.
#
#   sudo ./scripts/discover.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

require_root "$@"
load_config
find_lprint || die "lprint is not installed. Run ./setup.sh first."

info "lprint binary / version"
echo "$LPRINT"
"$LPRINT" --version 2>&1 | head -n1 || true

info "Drivers mentioning DYMO ('lprint drivers')"
"$LPRINT" drivers 2>&1 | grep -i dymo || echo "(none found)"

info "USB/network devices ('lprint devices')"
"$LPRINT" devices 2>&1 || true

info "Options and media for '$PRINTER_NAME' ('lprint options -d $PRINTER_NAME')"
"$LPRINT" options -d "$PRINTER_NAME" 2>&1 || echo "(printer '$PRINTER_NAME' not added yet; run ./setup.sh)"

info "Server"
ports="$(listen_ports || true)"
if [[ -z $ports ]]; then
  echo "(no lprint process is listening; is the service running? systemctl status lprint)"
else
  for p in $ports; do
    echo "Web UI:   http://$PRINTER_HOSTNAME.local:$p/"
    echo "IPP URL:  ipp://$PRINTER_HOSTNAME.local:$p/ipp/print/$PRINTER_NAME"
  done
fi
