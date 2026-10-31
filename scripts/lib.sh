#!/usr/bin/env bash
# Shared helpers for the peel scripts. Source this file; do not execute it.
# shellcheck shell=bash
#
# Everything here that can run without hardware is a function so tests/ can exercise it
# (config, option building, unit and udev rendering, file writes, ss parsing). Anything that
# talks to apt, snap, systemd or lprint stays in setup.sh.

PEEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN="${DRY_RUN:-0}"

# ---------------------------------------------------------------------------
# Constants. The dedicated-user model ran on a real Pi (see the OBSERVED list in the setup.sh
# header); they live here, in one place, so a correction is a one-line change.
# ---------------------------------------------------------------------------
SERVICE_USER=lprint
SERVICE_GROUP=lprint
SPOOL_DIR=/var/spool/lprint       # passed as -o spool-directory; observed OK for SERVICE_USER on the Pi
STATE_NAME=lprint                 # systemd StateDirectory= name (directory under /var/lib)
STATE_DIR=/var/lib/$STATE_NAME    # HOME of the service, where LPrint keeps ~/.lprint.conf (per its man page)
# Pinned because upstream docs say LPrint's default port is random in 8000-8999 (per upstream
# docs; the 1.3.1 default was not observed directly, since we pinned it).
DEFAULT_LISTEN_PORT=8631
USB_VENDOR_DYMO=0922
DEFAULT_PRINTER_NAME=DYMO_LabelWriter_450_Turbo   # the queue name LPrint gave the auto-added 450 Turbo (OBSERVED); keeps its URL
PEEL_STATE_DIR=/var/lib/peel
PRINTER_STATE_FILE=$PEEL_STATE_DIR/printer.state   # stamp of what setup.sh last applied (see printer_stamp)

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

# sudo_reexec_argv SCRIPT [ARGS...]: print, one per line, the command that re-runs SCRIPT under
# sudo. SCRIPT is passed to `bash` explicitly so this also works for `bash setup.sh`, where the
# file may not be executable or on PATH.
sudo_reexec_argv() {
  printf '%s\n' sudo -E bash "$@"
}

# Re-exec under sudo when not root. DRY_RUN needs no privileges, so it never escalates.
# Call as: require_root /absolute/path/to/script "$@"
require_root() {
  if [[ $DRY_RUN == 1 || $EUID -eq 0 ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || die "Must run as root and sudo is not installed. Re-run as root."
  info "Re-running under sudo"
  local argv=() line
  while IFS= read -r line; do
    argv+=("$line")
  done < <(sudo_reexec_argv "$@")
  exec "${argv[@]}"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# is_valid_port VALUE: succeeds for an integer from 1 to 65535 (decimal digits only).
is_valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  local n=$((10#$1))
  ((n >= 1 && n <= 65535))
}

# apply_config_defaults: fill every unset or empty config key.
apply_config_defaults() {
  : "${PRINTER_HOSTNAME:=labels}"
  : "${INSTALL_METHOD:=auto}"
  : "${SNAP_NAME:=lprint}"
  : "${LISTEN_PORT:=$DEFAULT_LISTEN_PORT}"
  : "${SERVER_OPTIONS:=}"
  : "${PRINTER_NAME:=$DEFAULT_PRINTER_NAME}"
  : "${DRIVER:=}"
  : "${DEVICE_URI:=}"
  : "${MEDIA_READY:=}"
  : "${PRINTER_OPTIONS:=}"
}

# shell_is_nologin SHELL: succeeds for a shell that cannot log in (nologin or /bin/false).
shell_is_nologin() {
  case $1 in
    */nologin | /bin/false) return 0 ;;
    *) return 1 ;;
  esac
}

# check_listen_port_bindable: die unless the dedicated non-root user can bind LISTEN_PORT.
# Applies to the apt path, where peel's own unit runs the server as SERVICE_USER.
check_listen_port_bindable() {
  ((LISTEN_PORT >= 1024)) \
    || die "LISTEN_PORT=$LISTEN_PORT is below 1024, and the dedicated user '$SERVICE_USER' cannot bind it. Set LISTEN_PORT in config.env to 1024 or more (it is ignored with INSTALL_METHOD=snap)."
}

# validate_config: die (naming the key to fix) on any invalid value.
validate_config() {
  [[ $PRINTER_HOSTNAME =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#PRINTER_HOSTNAME} -le 63 ]] \
    || die "PRINTER_HOSTNAME='$PRINTER_HOSTNAME' must be a lowercase DNS label (a-z, 0-9, '-'; at most 63 characters). Fix it in config.env."
  [[ $INSTALL_METHOD =~ ^(auto|apt|snap)$ ]] \
    || die "INSTALL_METHOD='$INSTALL_METHOD' must be auto, apt or snap. Fix it in config.env."
  [[ $SNAP_NAME =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || die "SNAP_NAME='$SNAP_NAME' must be a snap name (lowercase letters, digits, '-'). Fix it in config.env."
  is_valid_port "$LISTEN_PORT" \
    || die "LISTEN_PORT='$LISTEN_PORT' must be a number from 1 to 65535. Fix it in config.env (empty = $DEFAULT_LISTEN_PORT)."
  LISTEN_PORT=$((10#$LISTEN_PORT))   # normalize leading zeros so later arithmetic is decimal
  # On the apt path (auto may resolve to it) the server runs as a non-root user.
  [[ $INSTALL_METHOD == snap ]] || check_listen_port_bindable
  # SERVER_OPTIONS lands in a systemd ExecStart line, where '%' and '$' are expanded and a
  # newline would start a new directive. Allow only plain option characters.
  [[ $SERVER_OPTIONS =~ ^[A-Za-z0-9_=./:,@+\ -]*$ ]] \
    || die "SERVER_OPTIONS='$SERVER_OPTIONS' contains characters outside A-Z a-z 0-9 _ = . / : , @ + - and space. Fix it in config.env."
  [[ $SERVER_OPTIONS != *server-port* ]] \
    || die "SERVER_OPTIONS must not set server-port; peel pins it from LISTEN_PORT. Remove it from SERVER_OPTIONS in config.env."
  validate_printer_config
}

# validate_printer_config: die (naming the key to fix) on an invalid printer key. These values
# become arguments to the lprint CLI (never shell text), but they are still checked so a typo
# fails here with a clear message instead of as an obscure LPrint error. MEDIA_READY is not
# checked here: whether it is a valid media name is looked up on the printer (see
# media_ready_problem), which needs a running server.
validate_printer_config() {
  [[ $PRINTER_NAME =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
    || die "PRINTER_NAME='$PRINTER_NAME' must start with a letter or digit and contain only letters, digits, '_' and '-'. Fix it in config.env (empty = $DEFAULT_PRINTER_NAME)."
  [[ -z $DRIVER || $DRIVER =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "DRIVER='$DRIVER' is not a driver name (it must start with a letter or digit; then letters, digits, '.', '_', '-'). List them with: scripts/discover.sh. Fix it in config.env or leave it empty to discover it."
  [[ -z $DEVICE_URI || $DEVICE_URI =~ ^(usb|socket)://[^[:space:]]+$ ]] \
    || die "DEVICE_URI='$DEVICE_URI' must be a usb:// or socket:// URI without spaces. List devices with: scripts/discover.sh. Fix it in config.env or leave it empty to discover it."
  local kv key option_list=()
  read -ra option_list <<<"$PRINTER_OPTIONS"   # space-separated NAME=VALUE; read -a avoids glob expansion
  for kv in "${option_list[@]}"; do
    [[ $kv =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*=[A-Za-z0-9_.:/@+,-]+$ ]] \
      || die "PRINTER_OPTIONS entry '$kv' must look like NAME=VALUE (NAME starts with a letter or digit; plain characters only, no spaces). Fix it in config.env."
    key=${kv%%=*}
    case $key in
      media | media-ready | media-default)
        die "PRINTER_OPTIONS must not set '$key'; set MEDIA_READY instead. Fix it in config.env." ;;
    esac
  done
}

# load_config: source config.env (or, for DRY_RUN only, config.env.example), then default and
# validate. CONFIG_FILE overrides the path. config.env is sourced as bash: it is trusted input.
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
  apply_config_defaults
  validate_config
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

# build_server_options: the arguments after `lprint server`, on one line.
# OBSERVED on the Pi (lprint 1.3.1): server-port, spool-directory and log-file=- are accepted.
build_server_options() {
  local opts="-o server-port=$LISTEN_PORT -o spool-directory=$SPOOL_DIR -o log-file=-"
  if [[ -n $SERVER_OPTIONS ]]; then
    opts+=" $SERVER_OPTIONS"
  fi
  printf '%s' "$opts"
}

# render_unit TEMPLATE LPRINT_PATH: the systemd unit text for the dedicated-user service.
render_unit() {
  local content
  content="$(<"$1")"
  content="${content//@LPRINT@/"$2"}"
  content="${content//@SERVICE_USER@/"$SERVICE_USER"}"
  content="${content//@SERVICE_GROUP@/"$SERVICE_GROUP"}"
  content="${content//@STATE_NAME@/"$STATE_NAME"}"
  content="${content//@STATE_DIR@/"$STATE_DIR"}"
  content="${content//@SERVER_OPTIONS@/"$(build_server_options)"}"
  printf '%s\n' "$content"
}

# render_udev_rule: grant the DYMO USB device (vendor 0922) to SERVICE_GROUP.
render_udev_rule() {
  printf '%s\n' \
    "# Managed by peel (setup.sh). Lets the dedicated LPrint service user open DYMO USB devices." \
    "SUBSYSTEM==\"usb\", ENV{DEVTYPE}==\"usb_device\", ATTR{idVendor}==\"$USB_VENDOR_DYMO\", GROUP=\"$SERVICE_GROUP\", MODE=\"0660\""
}

# write_if_changed PATH CONTENT MODE: install CONTENT at PATH unless it already matches.
# Returns 0 when the file was (or, in DRY_RUN, would be) written, 1 when already up to date.
write_if_changed() {
  local path=$1 content=$2 mode=$3 tmp
  if [[ -f $path && "$(<"$path")" == "$content" ]]; then
    return 1
  fi
  if [[ $DRY_RUN == 1 ]]; then
    info "[dry-run] would write $path (mode $mode):"
    printf '%s\n' "$content" | sed 's/^/      /'
    return 0
  fi
  tmp="$(mktemp)"
  printf '%s\n' "$content" >"$tmp"
  install -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  return 0
}

# listen_ports_from_ss [PROCESS_NAME]: stdin is `ss -Hltn[p]` output; print the local port of
# each listening socket, sorted and unique. With PROCESS_NAME, keep only sockets whose process
# column names it (needs `ss -p` and root).
listen_ports_from_ss() {
  awk -v proc="${1:-}" '
    proc == "" || index($0, "\"" proc "\"") {
      n = split($4, a, ":")
      print a[n]
    }' | sort -un
}

# ---------------------------------------------------------------------------
# Decisions that setup.sh makes from observed state. Each takes its inputs as arguments so the
# tests can exercise it without systemd, ss or root.
# ---------------------------------------------------------------------------

# restart_reason UNIT_CHANGED ACTIVE OWNER EXPECTED_OWNER NEED_RELOAD
#   UNIT_CHANGED   1 when peel rewrote the unit file in this run, else 0
#   ACTIVE         `systemctl is-active` output (empty = unknown)
#   OWNER          user owning the service's main process (empty = no process)
#   NEED_RELOAD    `systemctl show -p NeedDaemonReload --value`, read BEFORE daemon-reload
# Prints why the service must be restarted and returns 0, or prints nothing and returns 1 when
# a healthy server should be left alone (a re-run must change nothing; OBSERVED: an
# unconditional restart changed the PID on a second run). The owner check covers the package's
# own root server, which its postinst starts before peel's unit exists.
restart_reason() {
  if [[ $1 == 1 ]]; then
    echo "the unit file changed"
  elif [[ $5 == yes ]]; then
    echo "systemd has not loaded the current unit file (NeedDaemonReload=yes)"
  elif [[ $2 != active ]]; then
    echo "the service is not active (state: ${2:-unknown})"
  elif [[ $3 != "$4" ]]; then
    echo "the server runs as '${3:-<no process>}', not '$4'"
  else
    return 1
  fi
}

# socket_path_aliases PATH: print PATH, then its other spelling, one per line. On Debian /var/run
# is a symlink to /run and `ss` reports a unix socket under the path it was bound with, so a
# socket bound as /var/run/x is the same file as /run/x. Other paths have no alias.
socket_path_aliases() {
  printf '%s\n' "$1"
  case $1 in
    /run/*) printf '%s\n' "/var$1" ;;
    /var/run/*) printf '%s\n' "${1#/var}" ;;
  esac
}

# socket_is_listened SS_OUTPUT PATH: succeeds when some process listens on the unix socket
# PATH, under either the /run or /var/run spelling. SS_OUTPUT is `ss -Hxlnp`; the local
# address is column 5. The inode in column 6 is the kernel SOCKET inode, not the file's inode,
# so it cannot be compared with stat output and is not used. Residual risk: a listener bound
# through some other path to the same file (a bind mount, a different symlink) is not seen.
socket_is_listened() {
  local alt
  alt="$(socket_path_aliases "$2" | tail -n 1)"
  awk -v p1="$2" -v p2="$alt" '$5 == p1 || $5 == p2 { found = 1 } END { exit !found }' <<<"$1"
}

# should_remove_socket EXISTS SS_OUTPUT PATH: succeeds only when PATH exists (EXISTS=1) and no
# process listens on it (see socket_is_listened for what that covers). The caller must pass
# real `ss` output (and skip the call if ss failed), or a live socket would look stale.
should_remove_socket() {
  [[ $1 == 1 ]] || return 1
  ! socket_is_listened "$2" "$3"
}

# hostname_change_notice OLD NEW: the warning printed when the hostname changes.
hostname_change_notice() {
  printf 'hostname changes from %s to %s: this host will answer as %s.local; reconnect there (a current ssh session by the old name may stop working).' "$1" "$2" "$2"
}

# root_server_risk SOURCE DRY_RUN: succeeds when the package's own root server may be running
# before the owner check has passed: the apt package is in use and this is not a dry run.
root_server_risk() {
  [[ $1 == apt && $2 != 1 ]]
}

# hosts_managed_by_cloud_init HOSTS_HEAD: succeeds when the first lines of /etc/hosts carry the
# header cloud-init writes when 'manage_etc_hosts' is True ("Your system has configured
# 'manage_etc_hosts' as True ..."), meaning cloud-init regenerates the file at boot.
hosts_managed_by_cloud_init() {
  grep -q "manage_etc_hosts" <<<"$1"
}

# cloud_init_hosts_notice: the warning printed when the hostname changes on such a system.
cloud_init_hosts_notice() {
  printf '%s' "cloud-init manages /etc/hosts here ('manage_etc_hosts' is True) and will regenerate it at boot, so peel's edit of the 127.0.1.1 line may not persist. OBSERVED on a Raspberry Pi Imager image: the new hostname itself persisted, but cloud-init rewrote /etc/hosts (the old name came back next to it); the new name still resolved. Setting the hostname in Raspberry Pi Imager avoids this."
}

# partial_failure_notice SERVICE: printed when a run fails after the apt package was installed
# but before the server was confirmed to run as the service user.
partial_failure_notice() {
  printf '%s\n' \
    "setup.sh stopped before it confirmed the server runs as '$SERVICE_USER'. The lprint package's own unit may have started a ROOT server during the install." \
    "Check with:  systemctl status ${1%.service}" \
    "To stop it and keep it from starting on boot:  sudo systemctl disable --now ${1%.service}" \
    "Then fix the cause above and re-run setup.sh. Nothing was stopped automatically."
}

# ---------------------------------------------------------------------------
# lprint: finding it and talking to the server
# ---------------------------------------------------------------------------

apt_pkg_installed() {
  command -v dpkg-query >/dev/null 2>&1 \
    && dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

snap_installed() {
  command -v snap >/dev/null 2>&1 && snap list "$1" >/dev/null 2>&1
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

# lprint_cli ARGS...: run the lprint CLI against the running server. OBSERVED on the Pi (apt,
# lprint 1.3.1): `sudo -u lprint lprint <subcommand>` reaches the dedicated user's server, while
# the same command as root did not. The snap server is root's, so the snap path runs the CLI as
# the invoking (root) user; that is UNVERIFIED on hardware. Needs LPRINT and LPRINT_SOURCE.
lprint_cli() {
  if [[ ${LPRINT_SOURCE:-} == snap ]]; then
    "$LPRINT" "$@"
  else
    sudo -u "$SERVICE_USER" "$LPRINT" "$@"
  fi
}

# ---------------------------------------------------------------------------
# Parsers for lprint output. Each reads the command's output on stdin. They are written against
# output captured on the Pi (lprint 1.3.1, tests/fixtures/lprint-*.txt), not against guesses.
# ---------------------------------------------------------------------------

# parse_attached_dymo: stdin is `lprint drivers`. OBSERVED: besides one line per driver
# (`NAME "Description" "device-id"`), LPrint prints one line per attached device that ends
# `-> DRIVER`: `Description (USB) (usb://...;MFG:DYMO;...;SERN:...;) -> dymo_lw-450-turbo`.
# That line is LPrint's own pairing of the attached device with a driver, so it is the source for
# discovery. Prints `DRIVER URI` for each attached DYMO device. (Taking the first field of every
# line that mentions "450 Turbo" would wrongly yield "DYMO" for that line.)
parse_attached_dymo() {
  awk 'tolower($0) ~ /mfg:dymo;/ && / -> [^ ]+$/ {
         uri = ""
         if (match($0, /usb:\/\/[^;)]+/)) uri = substr($0, RSTART, RLENGTH)
         print $NF, uri
       }'
}

# parse_driver_names: stdin is `lprint drivers`; prints every driver name, one per line.
parse_driver_names() {
  awk '/^[A-Za-z0-9._-]+ "/ { print $1 }'
}

# parse_dymo_usb_uris: stdin is `lprint devices` (OBSERVED: one URI per line, e.g.
# usb://DYMO/LabelWriter%20450%20Turbo?serial=...); prints the DYMO usb:// URIs.
parse_dymo_usb_uris() {
  grep -iE '^usb://dymo/' || true
}

# parse_media_names: stdin is `lprint options -d PRINTER`. OBSERVED lines look like
# `  -o media=NAME (1.1x3.5in or 28x88mm) (default)`; prints each NAME.
parse_media_names() {
  sed -n 's/^  -o media=\([^ ]*\).*/\1/p'
}

# parse_default_media: same input; prints the NAME marked `(default)`.
parse_default_media() {
  sed -n 's/^  -o media=\([^ ]*\) .*(default)$/\1/p'
}

# parse_printer_queue_names: stdin is `lprint printers` (OBSERVED: one display name per line, with
# spaces, e.g. `DYMO LabelWriter 450 Turbo`); prints each as the queue name used by `-d` and by
# the web UI / IPP path (spaces become underscores, OBSERVED: /ipp/print/DYMO_LabelWriter_450_Turbo).
parse_printer_queue_names() {
  sed -e '/^[[:space:]]*$/d' -e 's/[[:space:]]/_/g'
}

# ipp_attr NAME: stdin is scripts/ipp-attrs.py output; prints the value(s) of attribute NAME.
ipp_attr() {
  sed -n "s/^$1=//p"
}

# indent: stdin, indented for display inside an error message.
indent() {
  sed 's/^/       /'
}

# ipp_state_name N: the name of an IPP printer-state value.
ipp_state_name() {
  case $1 in
    3) echo idle ;;
    4) echo processing ;;
    5) echo stopped ;;
    *) echo unknown ;;
  esac
}

# count_lines TEXT: the number of non-empty lines in TEXT.
count_lines() {
  if [[ -z $1 ]]; then echo 0; else grep -c . <<<"$1"; fi
}

# select_dymo DRIVER_OUTPUT DEVICES_OUTPUT: apply the DRIVER and DEVICE_URI overrides to what
# was discovered. Prints `DRIVER URI`. Returns 1 with the reason on stderr (naming the config
# key to set) when the answer is not exactly one printer.
select_dymo() {
  local drivers_out=$1 devices_out=$2
  local attached uris uri driver n match
  attached="$(parse_attached_dymo <<<"$drivers_out")"
  uris="$(parse_dymo_usb_uris <<<"$devices_out" | sort -u)"

  if [[ -n $DEVICE_URI ]]; then
    uri=$DEVICE_URI
  else
    n="$(count_lines "$uris")"
    if ((n == 0)); then
      cat >&2 <<EOF
No DYMO USB printer found by 'lprint devices'.
     Check that the printer is powered on and the USB cable is firmly attached, then look for
     vendor $USB_VENDOR_DYMO in 'lsusb'. Re-run setup.sh when it shows up. If the printer is attached
     but LPrint does not list it:
$(usb_checks_hint "${SERVICE:-lprint.service}")
     To force a device anyway, set DEVICE_URI (and DRIVER) in config.env.
EOF
      return 1
    elif ((n > 1)); then
      cat >&2 <<EOF
Several DYMO USB printers found; peel manages exactly one:
$(indent <<<"$uris")
     Set DEVICE_URI in config.env to the one you want (the serial number tells them apart),
     or unplug the others, then re-run setup.sh.
EOF
      return 1
    fi
    uri=$uris
  fi

  if [[ -n $DRIVER ]]; then
    driver=$DRIVER
    if ! parse_driver_names <<<"$drivers_out" | grep -qFx -- "$driver"; then
      cat >&2 <<EOF
DRIVER='$driver' is not a driver LPrint knows. DYMO drivers it lists:
$(parse_driver_names <<<"$drivers_out" | grep -i dymo | indent)
     Fix DRIVER in config.env, or leave it empty to discover it.
EOF
      return 1
    fi
  else
    match="$(awk -v u="$uri" '$2 == u { print $1 }' <<<"$attached" | sort -u)"
    if [[ $(count_lines "$match") -ne 1 ]]; then
      cat >&2 <<EOF
LPrint did not pair the device $uri with exactly one driver in 'lprint drivers'.
     DYMO drivers it lists:
$(parse_driver_names <<<"$drivers_out" | grep -i dymo | indent)
     Set DRIVER in config.env to the right one (for the 450 Turbo, the one whose description
     reads "DYMO LabelWriter 450 Turbo"), then re-run setup.sh.
EOF
      return 1
    fi
    driver=$match
  fi
  printf '%s %s\n' "$driver" "$uri"
}

# ---------------------------------------------------------------------------
# Reconcile decisions (pure: arguments in, answer out)
# ---------------------------------------------------------------------------

# usb_checks_hint SERVICE: the steps that work today when the USB printer is not found or cannot
# be used (printed inside error messages, already indented).
usb_checks_hint() {
  cat <<EOF
       - lsusb: a DYMO printer shows as vendor $USB_VENDOR_DYMO. If it is missing, check the cable and power.
       - scripts/discover.sh: shows the drivers, devices and queues LPrint sees.
       - journalctl -u $1 -b --no-pager: the server's own errors (for example "Unable to claim USB interface").
       - Another process may hold the USB interface (for example CUPS, or an lprint started by hand): stop it, then re-run setup.sh.
EOF
}

# add_failed_message NAME SERVICE DELETED_NAMES: the error for a failed `lprint add`.
# DELETED_NAMES is the space-separated list of queues this run already deleted (empty if none):
# after a delete the printer is gone until the add succeeds, and the message says so.
add_failed_message() {
  local name=$1 service=$2 deleted=$3 d old=''
  for d in $deleted; do
    [[ $d == "$name" ]] || old="$old $d"
  done
  old=${old# }
  if [[ -z $deleted ]]; then
    printf "'lprint add' failed (message above). Nothing was deleted in this run, so the printer is as it was.\n"
  elif [[ " $deleted " == *" $name "* ]]; then
    printf "'lprint add' failed (message above) AFTER this run deleted %s. The printer queue '%s' is now GONE and has NOT been re-added.\n" "$deleted" "$name"
    [[ -z $old ]] || printf "     The old queue '%s' was removed too.\n" "$old"
    printf "     Fix the cause, then re-run ./setup.sh: it will add '%s' again.\n" "$name"
  else
    printf "'lprint add' failed (message above) AFTER this run deleted the old queue '%s'. The printer '%s' has NOT been added yet, so no printer is configured now.\n" "$old" "$name"
    printf "     Fix the cause, then re-run ./setup.sh: it will add '%s'.\n" "$name"
  fi
  printf "     If the printer is busy or claimed by another process, check:\n%s" "$(usb_checks_hint "$service")"
}

# printer_stamp NAME URI DRIVER: the identity stamp stored in PRINTER_STATE_FILE. The printer is
# deleted and re-added when, and only when, this changes (lprint modify takes no -v/-m, per
# upstream docs).
printer_stamp() {
  printf '%s|%s|%s' "$1" "$2" "$3"
}

# read_state_file: print the stamp file (empty if there is none yet).
read_state_file() {
  if [[ -f $PRINTER_STATE_FILE ]]; then
    cat "$PRINTER_STATE_FILE"
  fi
}

# write_state_file STAMP OPTIONS: record what setup.sh just applied (root only).
write_state_file() {
  install -d -m 0755 "$PEEL_STATE_DIR"
  printf 'printer=%s\noptions=%s\n' "$1" "$2" >"$PRINTER_STATE_FILE"
}

# stamp_value FILE_TEXT KEY: the value of KEY= in the stamp file text (empty if absent).
stamp_value() {
  sed -n "s/^$2=//p" <<<"$1" | head -n 1
}

# reconcile_action EXISTS STAMP WANT_STAMP: prints `add`, `readd` or `none`.
#   EXISTS  1 when a queue named PRINTER_NAME is present in `lprint printers`
#   STAMP   the identity recorded by the last successful run (empty = none)
# An existing queue without a matching stamp is re-added once: its URI and driver cannot be read
# back (neither the lprint CLI nor IPP reported them on the Pi; LPrint's own state file does list
# them, but it is an internal file that peel does not parse), so peel does not guess.
reconcile_action() {
  if [[ $1 != 1 ]]; then
    echo add
  elif [[ -n $2 && $2 == "$3" ]]; then
    echo none
  else
    echo readd
  fi
}

# options_removed OLD NEW: print the option names set in OLD but not in NEW (both are
# space-separated NAME=VALUE lists, as in PRINTER_OPTIONS). LPrint documents no way to unset an
# option on a queue (on the Pi, `modify -o NAME=` with an empty value left an invalid value), so
# setup.sh re-adds the printer to return a removed option to its default.
options_removed() {
  local old=() new=() kv key n found
  read -ra old <<<"$1"
  read -ra new <<<"$2"
  for kv in "${old[@]}"; do
    key=${kv%%=*}
    found=0
    for n in "${new[@]}"; do
      [[ ${n%%=*} == "$key" ]] && found=1
    done
    ((found == 1)) || printf '%s\n' "$key"
  done
}

# media_ready_problem MEDIA_READY VALID_NAMES: prints why MEDIA_READY cannot be applied and
# returns 0, or prints nothing and returns 1 when it is a valid media name.
media_ready_problem() {
  if [[ -z $1 ]]; then
    echo "MEDIA_READY is empty"
  elif ! grep -qFx -- "$1" <<<"$2"; then
    echo "MEDIA_READY='$1' is not a media name this printer supports"
  else
    return 1
  fi
}
