#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/service_common.sh"
service_init
load_critical_services "$REPO_DIR/input/critical_services.txt"
install_packages ufw iproute2
secure_service_permissions ufw
rules=("${EXTRA_PORTS[@]}")
# Keep an existing SSH daemon reachable, even if it is not marked critical.
if critical_service ssh || systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket; then
    ssh_settings=$(/usr/sbin/sshd -T)
    while read -r port; do [[ -z "$port" ]] || rules+=("$port/tcp"); done < <(awk '$1=="port" {print $2}' <<< "$ssh_settings")
fi
if systemctl is-active --quiet ssh.socket; then
    socket_listen=$(systemctl show -p Listen --value ssh.socket)
    while read -r endpoint; do
        port=${endpoint##*:}
        rules+=("$port/tcp")
    done < <(awk '{for(i=2;i<=NF;i++) if($i=="(Stream)") print $(i-1)}' <<< "$socket_listen")
fi
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r client client_port server server_port <<< "$SSH_CONNECTION"
    rules+=("$server_port/tcp")
fi
if critical_service apache2; then
    # Ask the running service for actual listeners, including custom/TLS ports.
    apache_pid=$(systemctl show -p MainPID --value apache2)
    [[ "$apache_pid" =~ ^[1-9][0-9]*$ ]] || { log 'FAILED: start Apache before configuring UFW'; exit 1; }
    listeners=$(ss -H -ltnp)
    apache_ports=$(awk -v pid="$apache_pid" 'index($0,"pid=" pid ",") {n=split($4,a,":"); print a[n]}' <<< "$listeners")
    [[ -n "$apache_ports" ]] || { log 'FAILED discovering Apache listeners; UFW left unchanged'; exit 1; }
    while read -r port; do rules+=("$port/tcp"); done <<< "$apache_ports"
fi
if critical_service vsftpd; then
    ftp_port=$(awk -F= '/^[[:space:]]*listen_port=/ {port=$2} END {print port ? port : 21}' /etc/vsftpd.conf)
    passive_min=$(awk -F= '/^[[:space:]]*pasv_min_port=/ {port=$2} END {print port}' /etc/vsftpd.conf)
    passive_max=$(awk -F= '/^[[:space:]]*pasv_max_port=/ {port=$2} END {print port}' /etc/vsftpd.conf)
    [[ -n "$passive_min" && -n "$passive_max" ]] || { log 'FAILED: configure vsftpd passive ports before enabling UFW'; exit 1; }
    rules+=("$ftp_port/tcp" "$passive_min:$passive_max/tcp")
fi
source "$REPO_DIR/service_helpers/managed_firewall.sh"
append_managed_firewall_rules
for rule in "${rules[@]}"; do
    valid_port_rule "$rule" || { log "FAILED invalid firewall port: $rule"; exit 1; }
done
backup_system_paths /etc/ufw /etc/default/ufw /etc/systemd/system
log "UFW before: $(ufw status verbose)"
# Place required allows ahead of deny rules. Preserve other scenario rules.
for rule in "${rules[@]}"; do
    ufw insert 1 allow "$rule"
    log "ENSURED UFW incoming allow: $rule"
done
ufw default deny incoming
ufw default allow outgoing
ufw logging low
ufw --force enable
systemctl enable --now ufw
systemctl is-enabled --quiet ufw
ufw status | grep -q '^Status: active$'
secure_service_permissions ufw
log "UFW after: $(ufw status verbose)"
