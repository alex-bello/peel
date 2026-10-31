#!/usr/bin/env bash
# peel setup, stage 1: get an LPrint server running on boot as a dedicated user on a pinned
# port. (Adding the printer comes in a later stage; no printer is configured here.)
#
# Idempotent: safe to re-run. Re-running re-applies config.env.
#
#   ./setup.sh              # apply (re-runs itself under sudo)
#   DRY_RUN=1 ./setup.sh    # print what would happen, change nothing, needs no root
#
# The apt path ALWAYS installs peel's own unit at /etc/systemd/system/lprint.service. It takes
# precedence over the unit the package ships in /usr/lib/systemd/system, so LISTEN_PORT and
# SERVER_OPTIONS always apply there. The package's postinst starts its own root server during
# `apt-get install`; peel's unit replaces it (a restart happens only when needed, see below).
# The snap path keeps the snap-managed root unit; LISTEN_PORT and SERVER_OPTIONS are ignored there.
#
# HARDWARE STATUS. Evidence comes from one real Raspberry Pi 3 Model B Rev 1.2, Debian 13
# trixie aarch64, lprint 1.3.1-1+b1 from apt, DYMO LabelWriter 450 Turbo (USB 0922:0021).
#
# OBSERVED on that Pi (2026-10-31):
#   - the deb ships lprint.service and its postinst enables and starts it (as root).
#   - `server-port`, `spool-directory` and `log-file=-` are accepted by `lprint server`.
#   - the non-root server (user lprint) runs and claims the USB device although the kernel
#     `usblp` driver was bound; the udev rule changed the node to root:lprint 0660.
#   - the spool directory works for the service user.
#   - `lprint --version` prints 1.3.1 (this script still takes the version from dpkg/snap).
#   - LPrint auto-adds the USB printer at server start (resource path
#     /ipp/print/DYMO_LabelWriter_450_Turbo); printer configuration is a later stage.
#   - the CLI works run as the service user (`sudo -u lprint lprint printers|devices|drivers|options`)
#     and FAILS run as root ("Unable to start server: No such file or directory") while a
#     stale /run/lprint.sock existed. The non-root server's CLI socket is /tmp/lprint<uid>.sock.
#     (That the stale socket is the CAUSE of the root failure is only SUSPECTED: see below.)
#   - the web UI answers HTTP 200 on the pinned port.
#   - avahi advertises the _ipp._tcp and _ipps._tcp records.
#   - the service user's home is /nonexistent, and `enable` coexists with the package's own
#     enable symlink (setup exited 0).
#   - CUPS refusal: with `cups-daemon` installed, setup exited 1 with the purge instructions
#     before any change (hostname, lprint PID, unit and udev mtimes and the hosts line were
#     identical before and after).
#   - restart only when needed: the first run after a unit change restarted the service once
#     ("the unit file changed"); a second run left the PID unchanged.
#   - state persistence: HOME=/var/lib/lprint is in the service environment, and
#     /var/lib/lprint/.lprint.conf was present after a config write plus a restart. LPrint
#     appears to write it on shutdown, not on every change (so restart after changing config).
#   - stale-socket handling: a genuinely stale /run/lprint.sock was removed ("nothing listens
#     on it"); a socket held by a live non-lprint process (python3) was left alone with a warning.
#   - one real reboot: the service came back active as `lprint` (pid 716) with no stale root
#     socket. That reboot ran the unit as it was BEFORE the last unit edits (pre-b4efdda).
#   - hostname rename: it persisted across a reboot, but on an image made with Raspberry Pi
#     Imager (trixie, cloud-init) cloud-init regenerated /etc/hosts as `127.0.1.1 labels chute`,
#     so the sed edit of /etc/hosts does not persist (harmless: `labels` still resolves).
#
# APPLIED, with a rationale that is an inference, not an observation:
#   - Removing a stale /run/lprint.sock is meant to let the root CLI work. The root CLI failure
#     was observed, but the socket was gone after the reboot and removing it was never shown to
#     make the root CLI work, so the stale socket is only the SUSPECTED cause.
#
# STILL UNVERIFIED on hardware: the final unit across a reboot, the partial-failure notice
# live, the whole snap path (including the snap names `raw-usb`, `avahi-control` and the
# start --enable call), printing itself, and the root CLI after stale-socket removal.
# If real hardware contradicts any assumption, setup.sh fails with a message rather than
# working around it. It never falls back to running the server as root on the apt path.
# The snap path is the one documented root exception (snap-managed root; amendment A1).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/scripts/lib.sh"
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

LPRINT=''             # path to the lprint binary
LPRINT_SOURCE=''      # apt | snap | other (installed by hand), set by step_packages
SERVICE=''            # systemd unit that runs the server
OWN_UNIT=0            # 1 on the apt path: peel's own unit (port pinned, dedicated user); 0 on the snap path
NEED_AVAHI_RESTART=0
UNIT_CHANGED=0        # 1 when this run rewrote the unit file
ROOT_SERVER_RISK=0    # 1 while the package's own root server may be running (see on_exit)
WAIT_SECONDS=30
EFFECTIVE_PORT=''     # the port the server is actually listening on
UNIT_PATH=/etc/systemd/system/lprint.service
UDEV_RULE_PATH=/etc/udev/rules.d/99-peel-dymo.rules
LPRINT_ROOT_SOCKET=/run/lprint.sock   # a stale one existed on the Pi after the package's root server (removal rationale: see the header)

# On any failure after the apt install and before the owner check, say what may be running.
on_exit() {
  local status=$?
  if ((status != 0 && ROOT_SERVER_RISK == 1)); then
    echo >&2
    partial_failure_notice "${SERVICE:-lprint.service}" >&2
  fi
}
trap on_exit EXIT

# Load config before escalating so config mistakes fail without a sudo prompt.
load_config
require_root "$SCRIPT_DIR/setup.sh" "$@"
if [[ $DRY_RUN == 1 ]]; then
  warn "DRY_RUN=1: nothing will be changed."
fi

# ---------------------------------------------------------------------------

step_preflight() {
  info "Preflight"
  if [[ $(uname -s) != Linux ]]; then
    [[ $DRY_RUN == 1 ]] || die "This script targets Raspberry Pi OS (Linux); found $(uname -s). Run it on the Pi."
    warn "Not on Linux; this dry run is only illustrative."
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found; this script targets Raspberry Pi OS / Debian. Use a Raspberry Pi OS Lite image."
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found; a systemd-based OS is required. Use a Raspberry Pi OS Lite image."
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    (. /etc/os-release && ok "OS: ${PRETTY_NAME:-unknown} ($(uname -m))")
  fi
}

# Mutating step; runs only after the read-only refusals (preflight, CUPS check) so a refused
# run changes nothing.
step_hostname() {
  info "Hostname -> $PRINTER_HOSTNAME"
  local current
  current="$(hostname -s 2>/dev/null || hostname)"
  if [[ $current == "$PRINTER_HOSTNAME" ]]; then
    ok "hostname already $PRINTER_HOSTNAME"
    return 0
  fi
  warn "$(hostname_change_notice "$current" "$PRINTER_HOSTNAME")"
  run hostnamectl set-hostname "$PRINTER_HOSTNAME"
  if hosts_managed_by_cloud_init "$(head -n 10 /etc/hosts 2>/dev/null || true)"; then
    warn "$(cloud_init_hosts_notice)"
  fi
  # Keep /etc/hosts in step, or sudo complains "unable to resolve host".
  # PRINTER_HOSTNAME is validated to [a-z0-9-], so it is safe inside the sed expression.
  if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
    run sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$PRINTER_HOSTNAME/" /etc/hosts
  elif [[ $DRY_RUN == 1 ]]; then
    info "[dry-run] would append '127.0.1.1 $PRINTER_HOSTNAME' to /etc/hosts"
  else
    printf '127.0.1.1\t%s\n' "$PRINTER_HOSTNAME" >>/etc/hosts
  fi
  NEED_AVAHI_RESTART=1
}

check_cups() {
  local pkg
  for pkg in cups cups-daemon; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii'; then
      die "Package '$pkg' is installed. CUPS can claim the USB printer and conflict with LPrint.
     Remove it with:  sudo apt-get purge -y cups cups-daemon cups-browsed  &&  sudo apt-get autoremove -y
     then re-run setup.sh."
    fi
  done
}

step_check_cups() {
  info "Checking that CUPS is absent"
  if ! command -v dpkg-query >/dev/null 2>&1; then
    warn "dpkg-query not found; cannot check for CUPS on this host."
    return 0
  fi
  check_cups
  ok "no CUPS"
}

# --- LPrint install --------------------------------------------------------

apt_has_lprint() {
  command -v apt-cache >/dev/null 2>&1 || return 1
  local cand
  cand="$(apt-cache policy lprint 2>/dev/null | awk '/Candidate:/ { print $2 }')"
  [[ -n $cand && $cand != '(none)' ]]
}

# Set LPRINT (path) if lprint is installed. /snap/bin is checked explicitly because sudo's
# secure_path often omits it.
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

apt_pkg_installed() {
  command -v dpkg-query >/dev/null 2>&1 \
    && dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

snap_installed() {
  command -v snap >/dev/null 2>&1 && snap list "$1" >/dev/null 2>&1
}

# Where an already-installed lprint came from: apt | snap | other. (apt wins if both exist.)
detect_lprint_source() {
  if apt_pkg_installed lprint; then
    echo apt
  elif snap_installed "$SNAP_NAME"; then
    echo snap
  else
    echo other
  fi
}

# The installed version, from dpkg or snap. (`lprint --version` also works on the apt build,
# observed; the package manager is the source of truth for both install paths.)
lprint_version() {
  case $LPRINT_SOURCE in
    apt) dpkg-query -W -f='${Version}' lprint ;;
    snap) snap list "$SNAP_NAME" | awk 'NR == 2 { print $2 }' ;;
    *) echo "unknown (not installed by apt or snap)" ;;
  esac
}

install_lprint_apt() {
  info "Installing lprint from apt"
  run apt-get install -y --no-install-recommends lprint
  # From here until the owner check passes, the package's own root unit may be running.
  [[ $DRY_RUN == 1 ]] || ROOT_SERVER_RISK=1
}

# Set ROOT_SERVER_RISK on every run that uses the apt package and has not yet passed the owner
# check, not only the run that installs it: an earlier partial run may have left the package's
# root server running.
mark_root_server_risk() {
  if root_server_risk "$LPRINT_SOURCE" "$DRY_RUN"; then
    ROOT_SERVER_RISK=1
  fi
}

# The snap runs the server as snap-managed root (documented exception, amendment A1).
install_lprint_snap() {
  info "Installing lprint from the snap '$SNAP_NAME' (runs as snap-managed root)"
  run apt-get install -y --no-install-recommends snapd
  run snap wait system seed.loaded
  local s
  for s in core avahi "$SNAP_NAME"; do
    if [[ $DRY_RUN != 1 ]] && snap_installed "$s"; then
      ok "snap '$s' already installed"
    else
      run snap install "$s"
    fi
  done
  # Plug names are taken from upstream docs and are unverified on hardware.
  local plug
  for plug in raw-usb avahi-control; do
    run snap connect "$SNAP_NAME:$plug" \
      || die "Could not connect $SNAP_NAME:$plug. Inspect 'snap connections $SNAP_NAME'; if the plug is named differently, that contradicts the unverified upstream docs: stop and report it."
  done
}

# Decide apt vs snap for a fresh install. Sets LPRINT_SOURCE.
choose_install_source() {
  case $INSTALL_METHOD in
    apt | snap) LPRINT_SOURCE=$INSTALL_METHOD ;;
    auto)
      if command -v apt-cache >/dev/null 2>&1; then
        if apt_has_lprint; then
          LPRINT_SOURCE=apt
        else
          warn "No 'lprint' package candidate in the apt repos for this release; falling back to the snap (runs as root)."
          LPRINT_SOURCE=snap
        fi
      elif [[ $DRY_RUN == 1 ]]; then
        warn "apt-cache not available here, so the apt/snap choice cannot be made; this plan shows the apt path."
        LPRINT_SOURCE=apt
      else
        die "apt-cache not found; cannot check whether 'lprint' is packaged. Run on Raspberry Pi OS."
      fi
      ;;
  esac
}

step_packages() {
  info "Packages"
  export DEBIAN_FRONTEND=noninteractive
  local missing=() pkg
  for pkg in avahi-daemon ca-certificates iproute2; do
    apt_pkg_installed "$pkg" || missing+=("$pkg")
  done

  local have_lprint=0
  if find_lprint; then
    have_lprint=1
    LPRINT_SOURCE="$(detect_lprint_source)"
    ok "lprint already installed: $LPRINT (source: $LPRINT_SOURCE)"
    mark_root_server_risk
    if [[ $INSTALL_METHOD != auto && $INSTALL_METHOD != "$LPRINT_SOURCE" ]]; then
      warn "INSTALL_METHOD=$INSTALL_METHOD but lprint was installed via $LPRINT_SOURCE; keeping the existing install."
    fi
  fi

  # Refresh the apt lists BEFORE choosing apt vs snap: on a fresh Pi the lists are empty, so
  # `apt-cache policy lprint` would report no candidate and wrongly pick the root snap.
  if ((${#missing[@]} > 0)) || ((have_lprint == 0)); then
    run apt-get update
  fi
  if ((have_lprint == 0)); then
    choose_install_source
  fi
  if ((${#missing[@]} > 0)); then
    run apt-get install -y --no-install-recommends "${missing[@]}"
  else
    ok "avahi-daemon, ca-certificates, iproute2 already installed"
  fi

  if [[ -z $LPRINT ]]; then
    case $LPRINT_SOURCE in
      apt) install_lprint_apt ;;
      snap) install_lprint_snap ;;
    esac
    if [[ $DRY_RUN == 1 ]]; then
      LPRINT=/usr/bin/lprint   # assumed apt location, for the plan only
      [[ $LPRINT_SOURCE != snap ]] || LPRINT=/snap/bin/lprint
    else
      find_lprint || die "lprint is still not on PATH after installation (looked in PATH and /snap/bin). Check the apt/snap output above."
      check_cups   # a package pulled in by the install must not have brought CUPS along
    fi
  fi

  if [[ $DRY_RUN == 1 && -z $(command -v "$LPRINT" 2>/dev/null) ]]; then
    ok "lprint would be installed via $LPRINT_SOURCE"
  else
    ok "lprint $(lprint_version) via $LPRINT_SOURCE"
  fi
}

# --- Dedicated user, USB access, spool -------------------------------------

step_service_user() {
  info "Service user '$SERVICE_USER', USB access and spool directory"
  if [[ $LPRINT_SOURCE == snap ]]; then
    ok "snap path: the server runs as the snap-managed root service, so peel adds no user, udev rule or spool directory. USB access is expected to come from the snap's raw-usb plug (unverified, gate item 6)."
    return 0
  fi

  # Create the group on its own first, so an already-existing group "lprint" does not make
  # `useradd --user-group` fail.
  if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    run groupadd --system "$SERVICE_GROUP"
  fi

  if getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    local shell pgroup
    shell="$(getent passwd "$SERVICE_USER" | cut -d: -f7)"
    if shell_is_nologin "$shell"; then
      ok "user '$SERVICE_USER' exists (shell $shell)"
    else
      warn "user '$SERVICE_USER' exists but has login shell '$shell'; peel does not change it. Fix with: sudo usermod -s /usr/sbin/nologin $SERVICE_USER"
    fi
    pgroup="$(id -gn "$SERVICE_USER" 2>/dev/null || true)"
    if [[ $pgroup != "$SERVICE_GROUP" ]]; then
      warn "user '$SERVICE_USER' has primary group '${pgroup:-unknown}', not '$SERVICE_GROUP'; peel does not change it. The unit sets Group=$SERVICE_GROUP explicitly, so the service still runs with that group."
    fi
  else
    # No home directory (OBSERVED: home is /nonexistent). The unit's StateDirectory/HOME gives
    # the service its writable state, so no usermod is needed for this or an existing user.
    run useradd --system -g "$SERVICE_GROUP" --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin "$SERVICE_USER"
  fi

  if write_if_changed "$UDEV_RULE_PATH" "$(render_udev_rule)" 644; then
    ok "udev rule written: $UDEV_RULE_PATH"
  else
    ok "udev rule file up to date: $UDEV_RULE_PATH"
  fi
  # Every run (not only when the file changed): a rule file that is current but was never
  # applied, e.g. after an earlier partial run, would otherwise leave the device node alone.
  run udevadm control --reload-rules
  run udevadm trigger --subsystem-match=usb --attr-match=idVendor="$USB_VENDOR_DYMO"

  # Spool only; the config/state directory is created by the unit (StateDirectory=).
  run install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "$SPOOL_DIR"
}

# --- systemd unit, start, verify -------------------------------------------

step_unit() {
  info "systemd service"

  if [[ $LPRINT_SOURCE == snap ]]; then
    local snap_unit=''
    if [[ $DRY_RUN != 1 ]]; then
      snap_unit="$(systemctl list-unit-files --no-legend "snap.${SNAP_NAME}.*.service" 2>/dev/null | awk 'NR == 1 { print $1 }')"
      [[ -n $snap_unit ]] || die "The snap '$SNAP_NAME' installed no systemd service. Inspect 'snap services $SNAP_NAME'; this contradicts the upstream docs, so stop and report it."
    else
      snap_unit="snap.${SNAP_NAME}.<service>.service"
    fi
    SERVICE=$snap_unit
    ok "the snap ships its own unit: $SERVICE"
    warn "snap path: LISTEN_PORT=$LISTEN_PORT and SERVER_OPTIONS are ignored (the snap-managed root unit is not modified), so the port is not pinned. The effective port is reported below."
    return 0
  fi

  # apt path (or an lprint installed by hand): peel ALWAYS installs its own unit. A unit in
  # /etc/systemd/system takes precedence over one the package ships in /usr/lib/systemd/system.
  [[ $LPRINT == /* ]] || die "Cannot write a unit: the lprint path '$LPRINT' is not absolute. Install lprint to a standard location."
  check_listen_port_bindable   # before anything is written
  SERVICE=lprint.service
  OWN_UNIT=1
  if [[ $DRY_RUN == 1 ]]; then
    info "[dry-run] whether the package also ships a unit is checked after the install; peel's unit is installed regardless"
  elif [[ -f /usr/lib/systemd/system/lprint.service || -f /lib/systemd/system/lprint.service ]]; then
    info "the package also ships lprint.service (it may have been started by the package); peel's unit in /etc/systemd/system takes precedence"
  else
    info "the package ships no lprint.service"
  fi
  info "Installing $UNIT_PATH (User=$SERVICE_USER, -o server-port=$LISTEN_PORT)"
  if write_if_changed "$UNIT_PATH" "$(render_unit "$PEEL_ROOT/systemd/lprint.service" "$LPRINT")" 644; then
    UNIT_CHANGED=1
  else
    ok "unit already up to date"
  fi
}

# Print the main PID's owner for SERVICE (empty if no process).
service_owner() {
  local pid
  pid="$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || true)"
  if [[ -n $pid && $pid != 0 ]]; then
    stat -c %U "/proc/$pid" 2>/dev/null || true
  fi
}

listening_ports() {
  ss -Hltnp 2>/dev/null | listen_ports_from_ss "$@"
}

service_failure_hint() {
  systemctl --no-pager status "$SERVICE" >&2 || true
  journalctl -u "$SERVICE" -b -n 30 --no-pager >&2 || true
}

# maybe_restart NEED_RELOAD: restart SERVICE only when restart_reason says so.
maybe_restart() {
  local reason
  if [[ $DRY_RUN == 1 ]]; then
    if ((UNIT_CHANGED == 1)); then
      info "[dry-run] restarting because the unit file changed"
      run systemctl restart "$SERVICE"
    else
      info "[dry-run] would restart $SERVICE only if needed (unit changed, not active, not owned by '$SERVICE_USER', or NeedDaemonReload); otherwise leave it running"
    fi
    return 0
  fi
  if reason="$(restart_reason "$UNIT_CHANGED" "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" "$(service_owner)" "$SERVICE_USER" "$1")"; then
    info "Restarting $SERVICE: $reason"
    systemctl restart "$SERVICE"
  else
    ok "$SERVICE is active as '$SERVICE_USER' with the current unit; not restarting"
  fi
}

# Remove a stale /run/lprint.sock left behind by the package's root server. A stale one was
# observed alongside the root CLI failing with "Unable to start server"; that it causes the
# failure is only suspected. Does not remove a socket that `ss` shows a process listening on,
# under either spelling (/run or /var/run); see socket_is_listened for the residual risk.
step_stale_socket() {
  [[ $LPRINT_SOURCE != snap ]] || return 0
  if [[ $DRY_RUN == 1 ]]; then
    info "[dry-run] would remove $LPRINT_ROOT_SOCKET if it exists and nothing listens on it"
    return 0
  fi
  local ss_out exists=0
  [[ -S $LPRINT_ROOT_SOCKET ]] && exists=1
  if ((exists == 0)); then
    ok "no stale $LPRINT_ROOT_SOCKET"
    return 0
  fi
  if ! ss_out="$(ss -Hxlnp 2>/dev/null)"; then
    warn "Could not run 'ss -xlnp'; leaving $LPRINT_ROOT_SOCKET alone."
    return 0
  fi
  if should_remove_socket "$exists" "$ss_out" "$LPRINT_ROOT_SOCKET"; then
    rm -f "$LPRINT_ROOT_SOCKET"
    ok "removed stale $LPRINT_ROOT_SOCKET (nothing listens on it)"
  else
    warn "$LPRINT_ROOT_SOCKET is in use by a listening process; left alone."
  fi
}

step_start() {
  info "Enable and start"
  run systemctl enable --now avahi-daemon.socket avahi-daemon.service
  if [[ $NEED_AVAHI_RESTART == 1 ]]; then
    run systemctl restart avahi-daemon.service
  fi

  if [[ $LPRINT_SOURCE == snap ]]; then
    # Unverified: `snap start --enable` starts the snap's services now and on boot.
    run snap start --enable "$SNAP_NAME"
  else
    # Read NeedDaemonReload BEFORE reloading (afterwards it is always "no"). Always reload
    # (cheap, idempotent), so a rerun after a partial failure never skips it. Restart only when
    # needed, so a re-run leaves a healthy server alone (restart_reason in scripts/lib.sh).
    local need_reload=''
    if [[ $DRY_RUN != 1 ]]; then
      need_reload="$(systemctl show -p NeedDaemonReload --value "$SERVICE" 2>/dev/null || true)"
    fi
    run systemctl daemon-reload
    run systemctl enable "$SERVICE"
    maybe_restart "$need_reload"
  fi

  if [[ $DRY_RUN == 1 ]]; then
    if [[ $OWN_UNIT == 1 ]]; then
      info "[dry-run] would wait up to ${WAIT_SECONDS}s for an lprint process listening on TCP port $LISTEN_PORT"
    else
      info "[dry-run] would wait up to ${WAIT_SECONDS}s for an lprint listener and report its port"
    fi
    if [[ $LPRINT_SOURCE != snap ]]; then
      info "[dry-run] would check the server process is owned by '$SERVICE_USER'"
      step_stale_socket
    fi
    return 0
  fi

  info "Waiting for the LPrint server to listen"
  local i ports=''
  for ((i = 0; i < WAIT_SECONDS; i++)); do
    if [[ $OWN_UNIT == 1 ]]; then
      ports="$(listening_ports lprint | grep -Fx "$LISTEN_PORT" || true)"
    else
      ports="$(listening_ports lprint || true)"
    fi
    [[ -z $ports ]] || break
    sleep 1
  done
  if [[ -z $ports ]]; then
    service_failure_hint
    if [[ $OWN_UNIT == 1 ]]; then
      die "Nothing is listening on port $LISTEN_PORT after ${WAIT_SECONDS}s. See the status and journal above (also: journalctl -u $SERVICE -b --no-pager).
     If the journal shows permission denied or cannot write for user '$SERVICE_USER' (state in $STATE_DIR, a socket, or $SPOOL_DIR),
     the dedicated-user assumption is contradicted: STOP and report it with that output. Do not switch the service to root."
    fi
    die "No lprint process is listening after ${WAIT_SECONDS}s. See the status and journal above (also: journalctl -u $SERVICE -b --no-pager)."
  fi
  EFFECTIVE_PORT="$(head -n1 <<<"$ports")"
  ok "server listening on port $EFFECTIVE_PORT"

  if [[ $LPRINT_SOURCE != snap ]]; then
    local owner
    owner="$(service_owner)"
    if [[ $owner != "$SERVICE_USER" ]]; then
      # Never leave a wrong-user (possibly root) server enabled across reboots.
      warn "Stopping and disabling $SERVICE so the wrong-user server does not come back on boot."
      ROOT_SERVER_RISK=0   # handled here; the failure below says what was done
      systemctl disable --now "$SERVICE" || warn "Could not disable $SERVICE; run: sudo systemctl disable --now $SERVICE"
      die "The lprint server runs as '${owner:-<no process>}', expected '$SERVICE_USER'. peel will not accept a root server on the apt path, so $SERVICE was stopped and disabled.
     Inspect the unit peel installed with: systemctl cat $SERVICE (it should show User=$SERVICE_USER and the $UNIT_PATH override),
     or stop and report so the dedicated-user decision can be revisited. Do not switch the service to root."
    fi
    ok "server process owner: $owner"
    ROOT_SERVER_RISK=0
    step_stale_socket
  fi
}

step_summary() {
  if [[ $DRY_RUN == 1 ]]; then
    info "Dry run complete; nothing was changed."
    return 0
  fi
  local owner='root (snap-managed; documented exception)'
  [[ $LPRINT_SOURCE == snap ]] || owner="$(service_owner)"
  echo
  ok "Done. The LPrint server is running; no printer is added yet."
  echo "    LPrint:     $(lprint_version) via $LPRINT_SOURCE ($LPRINT)"
  echo "    Service:    $SERVICE, enabled: $(systemctl is-enabled "$SERVICE" 2>/dev/null || echo unknown), active: $(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)"
  echo "    Owner:      $owner"
  echo "    Port:       $EFFECTIVE_PORT$([[ $OWN_UNIT == 1 ]] && echo ' (pinned by LISTEN_PORT)' || echo ' (NOT pinned: snap-managed unit)')"
  echo "    Web UI:     http://$PRINTER_HOSTNAME.local:$EFFECTIVE_PORT/   (answered HTTP 200 on the Pi's pinned port in recon)"
  [[ $LPRINT_SOURCE == snap ]] || echo "    State:      $STATE_DIR (HOME of the service; persistence not yet re-verified on hardware)"
  [[ $LPRINT_SOURCE == snap ]] || echo "    CLI:        sudo -u $SERVICE_USER lprint <subcommand>   (observed to work; as root it does not)"
  echo "    Logs:       journalctl -u $SERVICE -f"
}

step_preflight
step_check_cups
step_hostname
step_packages
step_service_user
step_unit
step_start
step_summary
