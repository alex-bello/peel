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
