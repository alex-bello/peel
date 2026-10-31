#!/usr/bin/env bash
# peel setup: turn a Raspberry Pi + USB DYMO LabelWriter 450 Turbo into a
# driverless (IPP Everywhere / AirPrint) network label printer using LPrint.
#
# Idempotent: safe to re-run. Re-running re-applies config.env.
#
#   sudo ./setup.sh              # apply
#   DRY_RUN=1 ./setup.sh         # print what would happen, change nothing
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/scripts/lib.sh"
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

STATE_DIR=/var/lib/peel
STATE_FILE="$STATE_DIR/printer.state"
UNIT_PATH=/etc/systemd/system/lprint.service

SERVICE=''
UNIT_CHANGED=0
NEED_AVAHI_RESTART=0

require_root "$@"
load_config
[[ $DRY_RUN == 1 ]] && warn "DRY_RUN=1: nothing will be changed."

# ---------------------------------------------------------------------------

step_preflight() {
  info "Preflight"
  if [[ $(uname -s) != Linux ]]; then
    [[ $DRY_RUN == 1 ]] || die "This script targets Raspberry Pi OS (Linux); found $(uname -s)."
    warn "Not on Linux; dry run output is only illustrative."
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found; this script targets Raspberry Pi OS / Debian."
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found; a systemd-based OS is required."
  # shellcheck source=/dev/null
  [[ -r /etc/os-release ]] && . /etc/os-release && ok "OS: ${PRETTY_NAME:-unknown} ($(uname -m))"
  return 0
}

step_hostname() {
  info "Hostname -> $PRINTER_HOSTNAME"
  local current
  current="$(hostname -s 2>/dev/null || hostname)"
  if [[ $current == "$PRINTER_HOSTNAME" ]]; then
    ok "hostname already $PRINTER_HOSTNAME"
    return 0
  fi
  run hostnamectl set-hostname "$PRINTER_HOSTNAME"
  # Keep /etc/hosts in step, or sudo complains "unable to resolve host".
  if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
    run sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$PRINTER_HOSTNAME/" /etc/hosts
  else
    run bash -c "printf '127.0.1.1\t%s\n' '$PRINTER_HOSTNAME' >> /etc/hosts"
  fi
  NEED_AVAHI_RESTART=1
}

step_check_cups() {
  info "Checking that CUPS is absent"
  local pkg
  for pkg in cups cups-daemon; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii'; then
      die "Package '$pkg' is installed. CUPS can claim the USB printer and conflict with LPrint.
     Remove it with:  sudo apt-get purge -y cups cups-daemon cups-browsed  &&  sudo apt-get autoremove -y
     then re-run setup.sh."
    fi
  done
  ok "no CUPS"
}

apt_has_lprint() {
  command -v apt-cache >/dev/null 2>&1 || return 1
  local cand
  cand="$(apt-cache policy lprint 2>/dev/null | awk '/Candidate:/ { print $2 }')"
  [[ -n $cand && $cand != '(none)' ]]
}

install_lprint_apt() {
  info "Installing lprint from apt"
  run apt-get install -y lprint
}

install_lprint_snap() {
  info "Installing lprint from the snap '$SNAP_NAME'"
  run apt-get install -y snapd
  run snap wait system seed.loaded
  run snap install "$SNAP_NAME"
  # Best effort: the snap may need an explicit grant to reach USB devices.
  # The interface name is unverified, so a failure is only a warning.
  run snap connect "$SNAP_NAME:raw-usb" \
    || warn "Could not connect $SNAP_NAME:raw-usb. If no USB printer shows up later, see 'snap connections $SNAP_NAME'."
}

step_packages() {
  info "Packages"
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update
  run apt-get install -y --no-install-recommends avahi-daemon ca-certificates iproute2

  if find_lprint; then
    ok "lprint already installed: $LPRINT"
  else
    case $INSTALL_METHOD in
      apt)  install_lprint_apt ;;
      snap) install_lprint_snap ;;
      auto)
        if [[ $DRY_RUN == 1 ]] && ! command -v apt-cache >/dev/null 2>&1; then
          info "[dry-run] would check 'apt-cache policy lprint'; install via apt if packaged, else via snap"
        elif apt_has_lprint; then
          install_lprint_apt
        else
          warn "No 'lprint' package candidate in the apt repos for this release; falling back to snap."
          install_lprint_snap
        fi
        ;;
    esac
    if [[ $DRY_RUN == 1 ]]; then
      LPRINT=lprint
    else
      find_lprint || die "lprint is still not on PATH after installation (looked in PATH and /snap/bin)."
    fi
  fi
  [[ $DRY_RUN == 1 && -z $LPRINT ]] && LPRINT=lprint
  if command -v "$LPRINT" >/dev/null 2>&1; then
    ok "using $LPRINT ($("$LPRINT" --version 2>&1 | head -n1 || true))"
  else
    ok "using $LPRINT (not installed yet)"
  fi
}

# Pick the systemd unit that runs the lprint server, installing ours if nothing ships one.
step_service() {
  info "systemd service"

  local snap_unit=''
  if [[ $DRY_RUN != 1 ]] && command -v systemctl >/dev/null 2>&1; then
    snap_unit="$(systemctl list-unit-files --no-legend "snap.${SNAP_NAME}.*.service" 2>/dev/null \
      | awk 'NR == 1 { print $1 }')"
  fi

  local server_opts=''
  [[ -n $LISTEN_PORT ]] && server_opts+=" -o listen-port=$LISTEN_PORT"
  [[ -n $SERVER_OPTIONS ]] && server_opts+=" $SERVER_OPTIONS"

  if [[ -n $snap_unit ]]; then
    SERVICE="$snap_unit"
    ok "the snap ships its own unit: $SERVICE"
    [[ -z $server_opts ]] || warn "LISTEN_PORT/SERVER_OPTIONS are ignored with the snap's own unit."
  elif [[ -f /usr/lib/systemd/system/lprint.service || -f /lib/systemd/system/lprint.service ]]; then
    SERVICE=lprint.service
    ok "the package ships its own unit: $SERVICE"
    [[ -z $server_opts ]] || warn "LISTEN_PORT/SERVER_OPTIONS are ignored with the package's own unit (use 'systemctl edit lprint')."
  else
    SERVICE=lprint.service
    info "No unit shipped; installing $UNIT_PATH"
    local content tmp
    content="$(<"$PEEL_ROOT/systemd/lprint.service")"
    content="${content//@LPRINT@/$LPRINT}"
    content="${content//@SERVER_OPTIONS@/$server_opts}"
    if [[ -f $UNIT_PATH && "$(<"$UNIT_PATH")" == "$content" ]]; then
      ok "unit already up to date"
    else
      UNIT_CHANGED=1
      if [[ $DRY_RUN == 1 ]]; then
        info "[dry-run] would write $UNIT_PATH:"
        printf '%s\n' "$content" | sed 's/^/      /'
      else
        tmp="$(mktemp)"
        printf '%s\n' "$content" >"$tmp"
        install -m 644 "$tmp" "$UNIT_PATH"
        rm -f "$tmp"
      fi
    fi
  fi

  [[ $UNIT_CHANGED == 1 ]] && run systemctl daemon-reload
  run systemctl enable --now avahi-daemon
  [[ $NEED_AVAHI_RESTART == 1 ]] && run systemctl restart avahi-daemon

  if [[ $DRY_RUN == 1 ]]; then
    run systemctl enable --now "$SERVICE"
    return 0
  fi
  run systemctl enable "$SERVICE"
  if [[ $UNIT_CHANGED == 1 ]]; then
    run systemctl restart "$SERVICE"
  else
    run systemctl start "$SERVICE"
  fi

  info "Waiting for the LPrint server to listen"
  local i
  for ((i = 0; i < 30; i++)); do
    [[ -n "$(listen_ports)" ]] && break
    sleep 1
  done
  if [[ -z "$(listen_ports)" ]]; then
    systemctl --no-pager status "$SERVICE" >&2 || true
    die "No 'lprint' process is listening after 30s. Check: journalctl -u $SERVICE -b --no-pager"
  fi
  ok "server listening on port(s): $(listen_ports | paste -sd, -)"
}

# First whitespace-delimited field of the single matching driver line.
discover_driver() {
  local out names
  out="$("$LPRINT" drivers 2>&1)" || die "'$LPRINT drivers' failed:
$out"
  # "450 Turbo" but not "450 Twin Turbo".
  names="$(grep -iE '450[ _-]turbo' <<<"$out" | awk '{ print $1 }' | sort -u || true)"
  case $(count_lines "$names") in
    1) printf '%s' "$names" ;;
    0) die "No driver matching '450 Turbo' in '$LPRINT drivers'. DYMO drivers found:
$(grep -i dymo <<<"$out" || echo '  (none)')
     Set DRIVER in config.env to the right name." ;;
    *) die "Several drivers match '450 Turbo':
$names
     Set DRIVER in config.env to the one you want." ;;
  esac
}

# The single usb:// URI whose line mentions DYMO.
discover_uri() {
  local out uris
  out="$("$LPRINT" devices 2>&1)" || die "'$LPRINT devices' failed:
$out"
  uris="$(grep -i dymo <<<"$out" | grep -ioE 'usb://[^[:space:]"]+' | sort -u || true)"
  case $(count_lines "$uris") in
    1) printf '%s' "$uris" ;;
    0) die "No DYMO USB printer found by '$LPRINT devices'. Output was:
$out
     Check the USB cable, that the printer is powered on, and 'lsusb' (DYMO is vendor 0922).
     With the snap, also check 'snap connections $SNAP_NAME'. See README > Troubleshooting." ;;
    *) die "Several DYMO USB printers found:
$uris
     Set DEVICE_URI in config.env to the one you want." ;;
  esac
}

printer_exists() {
  "$LPRINT" options -d "$PRINTER_NAME" >/dev/null 2>&1
}

step_printer() {
  info "Printer '$PRINTER_NAME'"
  if [[ $DRY_RUN == 1 ]] && ! "$LPRINT" drivers >/dev/null 2>&1; then
    info "[dry-run] would discover the driver via '$LPRINT drivers' (config DRIVER='${DRIVER:-auto}')"
    info "[dry-run] would discover the USB URI via '$LPRINT devices' (config DEVICE_URI='${DEVICE_URI:-auto}')"
    info "[dry-run] would run: $LPRINT add -d $PRINTER_NAME -v <uri> -m <driver>   (or delete + re-add if the URI/driver changed)"
    info "[dry-run] would run: $LPRINT modify -d $PRINTER_NAME -o media=${MEDIA_READY:-<unset>} -o media-ready=${MEDIA_READY:-<unset>}"
    return 0
  fi

  local driver="$DRIVER" uri="$DEVICE_URI"
  [[ -n $driver ]] || driver="$(discover_driver)"
  [[ -n $uri ]] || uri="$(discover_uri)"
  ok "driver: $driver"
  ok "device: $uri"

  # LPrint has no declarative "ensure" command, and `modify` flags for the URI
  # and driver are unverified, so reconcile by remembering what we last applied
  # and deleting + re-adding only when it changed.
  local stamp="$PRINTER_NAME|$uri|$driver"
  if printer_exists && [[ -f $STATE_FILE && "$(<"$STATE_FILE")" == "$stamp" ]]; then
    ok "printer already added with these settings"
  else
    if printer_exists; then
      info "Printer exists with different/unknown settings; re-adding"
      run "$LPRINT" delete -d "$PRINTER_NAME" \
        || warn "delete failed; continuing, 'add' will fail loudly if the printer really is still there"
    fi
    run "$LPRINT" add -d "$PRINTER_NAME" -v "$uri" -m "$driver"
    run mkdir -p "$STATE_DIR"
    if [[ $DRY_RUN != 1 ]]; then printf '%s' "$stamp" >"$STATE_FILE"; fi
  fi

  # Capture first: piping straight into `grep -q` can SIGPIPE the producer under pipefail.
  local options_out='' opts=() kv
  if [[ $DRY_RUN != 1 ]]; then options_out="$("$LPRINT" options -d "$PRINTER_NAME" 2>&1 || true)"; fi
  if [[ -n $MEDIA_READY ]]; then
    # Soft check: the output format is unverified, and `modify` rejects bad names itself.
    if [[ $DRY_RUN != 1 ]] && ! grep -Fq -- "$MEDIA_READY" <<<"$options_out"; then
      warn "MEDIA_READY='$MEDIA_READY' was not found in '$LPRINT options -d $PRINTER_NAME'; LPrint may reject it. Media lines:"
      grep -i media <<<"$options_out" >&2 || true
    fi
    opts+=(-o "media=$MEDIA_READY" -o "media-ready=$MEDIA_READY")
  else
    warn "MEDIA_READY is empty; the driver default stays in effect. Media lines from '$LPRINT options':"
    grep -i media <<<"$options_out" >&2 || true
    warn "Pick one, put it in config.env as MEDIA_READY, and re-run setup.sh."
  fi
  for kv in $PRINTER_OPTIONS; do opts+=(-o "$kv"); done
  if ((${#opts[@]} > 0)); then
    run "$LPRINT" modify -d "$PRINTER_NAME" "${opts[@]}"
  fi
}

step_summary() {
  [[ $DRY_RUN == 1 ]] && { info "Dry run complete; nothing was changed."; return 0; }
  local port host
  port="$(listen_ports | head -n1)"
  host="$PRINTER_HOSTNAME.local"
  echo
  ok "Done. peel is set up."
  echo "    Web UI:   http://$host:$port/"
  echo "    IPP URL:  ipp://$host:$port/ipp/print/$PRINTER_NAME"
  echo "    (the Web UI's printer page shows the authoritative printer-uri; use it if this differs)"
  echo
  echo "    Test print:  sudo ./scripts/test-print.sh"
  echo "    Inspect:     sudo ./scripts/discover.sh"
  echo "    Logs:        journalctl -u ${SERVICE:-lprint.service} -f"
}

step_preflight
step_hostname
step_check_cups
step_packages
step_service
step_printer
step_summary
