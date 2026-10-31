#!/usr/bin/env bash
# Small decision helpers in scripts/lib.sh: sudo re-exec argv, nologin shells. No hardware.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/lib.sh
source "$PEEL_ROOT/scripts/lib.sh"

# sudo re-exec runs the script through bash, so `bash setup.sh` (not executable, not on PATH)
# still works, and arguments with spaces survive one per line.
assert_eq "re-exec without args" $'sudo\n-E\nbash\n/opt/peel/setup.sh' \
  "$(sudo_reexec_argv /opt/peel/setup.sh)"
assert_eq "re-exec keeps args intact" $'sudo\n-E\nbash\n/opt/peel/setup.sh\n--flag\na b' \
  "$(sudo_reexec_argv /opt/peel/setup.sh --flag 'a b')"

# DRY_RUN and root never escalate (require_root returns instead of exec'ing sudo).
assert_true "DRY_RUN does not re-exec" bash -c "
  source '$PEEL_ROOT/scripts/lib.sh'; DRY_RUN=1; require_root /nonexistent/setup.sh"

# Service user helpers.
for sh in /usr/sbin/nologin /sbin/nologin /bin/false; do
  assert_true "$sh counts as no login" shell_is_nologin "$sh"
done
for sh in /bin/bash /bin/sh /usr/bin/zsh ''; do
  assert_false "'$sh' counts as a login shell" shell_is_nologin "$sh"
done

# restart_reason UNIT_CHANGED ACTIVE OWNER EXPECTED_OWNER NEED_RELOAD: restart only when needed.
assert_false "healthy server, unit unchanged: no restart" restart_reason 0 active lprint lprint no
assert_false "healthy server, NeedDaemonReload empty (unknown): no restart" restart_reason 0 active lprint lprint ''
assert_true "unit changed: restart" restart_reason 1 active lprint lprint no
assert_true "NeedDaemonReload=yes: restart" restart_reason 0 active lprint lprint yes
assert_true "inactive: restart" restart_reason 0 inactive '' lprint no
assert_true "failed: restart" restart_reason 0 failed '' lprint no
assert_true "activating (crash loop): restart" restart_reason 0 activating lprint lprint no
assert_true "package's root server is running: restart" restart_reason 0 active root lprint no
assert_true "active with no main process: restart" restart_reason 0 active '' lprint no
assert_true "empty is-active output: restart" restart_reason 0 '' '' lprint no
assert_eq "reason names the root owner" "the server runs as 'root', not 'lprint'" "$(restart_reason 0 active root lprint no)"
assert_eq "reason names the unit change" "the unit file changed" "$(restart_reason 1 active lprint lprint no)"
assert_eq "no output when no restart is needed" "" "$(restart_reason 0 active lprint lprint no)"

# Stale root socket: removed only when it exists and nothing listens on it. Columns of
# `ss -Hxlnp`: Netid State Recv-Q Send-Q LocalAddr Inode Peer PeerInode Process.
# REAL captures, captured on the Pi 2026-10-31:
real_lprint='u_str LISTEN 0      0                             /tmp/lprint999.sock 16564            * 0    users:(("lprint",pid=2494,fd=11))'
real_python='u_str LISTEN 0      0                                /run/lprint.sock 23197 * 0 users:(("python3",pid=3552,fd=3))'
# SYNTHETIC (hand-written): unrelated listeners, and a root lprint server bound as /var/run.
syn_other='u_str LISTEN 0 4096 /run/systemd/private 2222 * 0 users:(("systemd",pid=1,fd=40))'
syn_lprint_run='u_str LISTEN 0 4096 /run/lprint.sock 4444 * 0 users:(("lprint",pid=700,fd=4))'
syn_lprint_varrun='u_str LISTEN 0 4096 /var/run/lprint.sock 4445 * 0 users:(("lprint",pid=700,fd=4))'
ss_stale="$syn_other
$real_lprint"
assert_true "stale: exists and no listener on it" should_remove_socket 1 "$ss_stale" /run/lprint.sock
assert_true "stale: no ss listeners at all" should_remove_socket 1 "" /run/lprint.sock
assert_false "live (real capture): a non-lprint process listens on /run/lprint.sock" should_remove_socket 1 "$real_python" /run/lprint.sock
assert_false "live (real capture) among other listeners" should_remove_socket 1 "$ss_stale
$real_python" /run/lprint.sock
assert_false "live (synthetic): an lprint process listens on /run/lprint.sock" should_remove_socket 1 "$syn_lprint_run" /run/lprint.sock
assert_false "live under the /var/run spelling is not removed" should_remove_socket 1 "$syn_lprint_varrun" /run/lprint.sock
assert_false "live under /run is not removed when asked as /var/run" should_remove_socket 1 "$syn_lprint_run" /var/run/lprint.sock
assert_true "a /var/run listener on another socket does not block removal" should_remove_socket 1 "u_str LISTEN 0 4096 /var/run/other.sock 5555 * 0 users:((\"x\",pid=9,fd=3))" /run/lprint.sock
assert_false "absent socket: nothing to remove" should_remove_socket 0 "$ss_stale" /run/lprint.sock
assert_false "a listened-on socket is never removed (other path, real capture)" should_remove_socket 1 "$real_lprint" /tmp/lprint999.sock
assert_true "socket_is_listened finds the real /tmp capture" socket_is_listened "$real_lprint" /tmp/lprint999.sock
assert_true "socket_is_listened finds the real python3 capture" socket_is_listened "$real_python" /run/lprint.sock
assert_false "socket_is_listened ignores other paths" socket_is_listened "$ss_stale" /run/lprint.sock
assert_false "socket_is_listened does not match by inode column" socket_is_listened "$real_python" 23197
assert_eq "aliases of a /run path" $'/run/lprint.sock\n/var/run/lprint.sock' "$(socket_path_aliases /run/lprint.sock)"
assert_eq "aliases of a /var/run path" $'/var/run/lprint.sock\n/run/lprint.sock' "$(socket_path_aliases /var/run/lprint.sock)"
assert_eq "no alias for /tmp" "/tmp/lprint999.sock" "$(socket_path_aliases /tmp/lprint999.sock)"

# ROOT_SERVER_RISK applies on every apt run that has not passed the owner check, not only the
# run that installs the package; never in a dry run and never on the snap path.
assert_true "apt source: root server risk" root_server_risk apt 0
assert_false "apt source, dry run: no risk" root_server_risk apt 1
assert_false "snap source: no risk" root_server_risk snap 0
assert_false "other source: no risk" root_server_risk other 0
assert_false "unset source: no risk" root_server_risk '' 0
assert_true "setup.sh sets the risk for an already-installed apt package" \
  grep -A1 'ok "lprint already installed' "$PEEL_ROOT/setup.sh" | grep -q mark_root_server_risk

# cloud-init managed /etc/hosts. The first line is as observed on the Pi (Raspberry Pi Imager,
# trixie); the rest of the header is cloud-init's standard hosts template text, written from
# memory (SYNTHETIC), followed by the line observed after the reboot.
cloud_hosts="# Your system has configured 'manage_etc_hosts' as True.
# As a result, if you wish for changes to this file to persist
# then you will need to either
# a.) make changes to the master file in /etc/cloud/templates/hosts.debian.tmpl
# b.) change or remove the value of 'manage_etc_hosts' in
#     /etc/cloud/cloud.cfg or cloud-config from user-data
#
127.0.1.1 labels chute
127.0.0.1 localhost"
plain_hosts="127.0.0.1	localhost
127.0.1.1	chute
::1		localhost ip6-localhost ip6-loopback"
assert_true "cloud-init hosts header is detected" hosts_managed_by_cloud_init "$cloud_hosts"
assert_false "a plain hosts file is not cloud-init managed" hosts_managed_by_cloud_init "$plain_hosts"
assert_false "empty hosts content is not cloud-init managed" hosts_managed_by_cloud_init ""
assert_true "cloud-init notice says cloud-init regenerates the file" \
  grep -qF 'will regenerate it at boot' <<<"$(cloud_init_hosts_notice)"
assert_true "cloud-init notice points at Raspberry Pi Imager" \
  grep -qF 'Raspberry Pi Imager' <<<"$(cloud_init_hosts_notice)"

# Notices.
assert_eq "hostname notice names old and new" \
  "hostname changes from chute to labels: this host will answer as labels.local; reconnect there (a current ssh session by the old name may stop working)." \
  "$(hostname_change_notice chute labels)"
assert_true "partial failure notice gives the exact disable command" \
  grep -qF 'sudo systemctl disable --now lprint' <<<"$(partial_failure_notice lprint.service)"

finish
