#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/service_common.sh"
service_init
require_commands pfctl sockstat kldstat kldload
load_critical_services "$REPO_DIR/input/critical_services.txt"
rules=("${EXTRA_PORTS[@]}")

# Use live sockets, including custom command-line ports, to preserve SSH access.
ssh_ports=$(listening_tcp_ports sshd)
while read -r port; do [[ -z "$port" ]] || rules+=("$port/tcp"); done <<< "$ssh_ports"
if critical_service ssh && [[ -z "$ssh_ports" ]]; then
    log 'FAILED: start sshd before configuring PF so its real listening ports can be preserved'
    exit 1
fi
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r client client_port server server_port <<< "$SSH_CONNECTION"
    rules+=("$server_port/tcp")
fi
if critical_service apache2; then
    apache_ports=$(listening_tcp_ports httpd)
    [[ -n "$apache_ports" ]] || { log 'FAILED: start Apache24 before configuring PF'; exit 1; }
    while read -r port; do rules+=("$port/tcp"); done <<< "$apache_ports"
fi
if critical_service vsftpd; then
    ftp_ports=$(listening_tcp_ports vsftpd)
    [[ -n "$ftp_ports" ]] || { log 'FAILED: start standalone vsftpd before configuring PF'; exit 1; }
    while read -r port; do rules+=("$port/tcp"); done <<< "$ftp_ports"
    ftp_config=$(sysrc -n vsftpd_config 2>/dev/null || true)
    ftp_config=${ftp_config:-/usr/local/etc/vsftpd.conf}
    [[ -r "$ftp_config" ]] || { log "FAILED unreadable vsftpd configuration: $ftp_config"; exit 1; }
    passive_min=$(awk -F= '/^[[:space:]]*pasv_min_port=/ {value=$2} END {gsub(/[[:space:]]/, "", value); print value}' "$ftp_config")
    passive_max=$(awk -F= '/^[[:space:]]*pasv_max_port=/ {value=$2} END {gsub(/[[:space:]]/, "", value); print value}' "$ftp_config")
    [[ -n "$passive_min" && -n "$passive_max" ]] || { log 'FAILED: configure vsftpd passive ports before enabling PF'; exit 1; }
    rules+=("$passive_min:$passive_max/tcp")
fi
source "$REPO_DIR/service_helpers/managed_firewall.sh"
append_managed_firewall_rules
for rule in "${rules[@]}"; do
    valid_port_rule "$rule" || { log "FAILED invalid firewall port: $rule"; exit 1; }
done

config=$(sysrc -n pf_rules 2>/dev/null || true)
config=${config:-/etc/pf.conf}
[[ "$config" == /* && ! -L "$config" ]] || { log 'FAILED pf_rules must be an absolute regular file path'; exit 1; }
[[ ! -e "$config" || -f "$config" ]] || { log "FAILED unexpected PF configuration file type: $config"; exit 1; }
candidate=$(mktemp /etc/pf.cyberpatriot.XXXXXX)
write_pf_rules() {
    local rule port protocol
    printf '%s\n' '# Managed by CyberPatriot FreeBSD PF' \
        '# Add required application ports to input/critical_services.txt and rerun.' \
        'set skip on lo0' 'block in all' 'pass out all keep state' \
        '# ICMP supports diagnostics, path MTU discovery and IPv6 neighbor discovery.' \
        'pass in inet proto icmp all keep state' \
        'pass in inet6 proto ipv6-icmp all keep state' \
        '# DHCP replies may arrive before a client has an address.' \
        'pass in inet proto udp from any port 67 to any port 68 keep state' \
        'pass in inet6 proto udp from any port 547 to any port 546 keep state'
    for rule in "${rules[@]}"; do
        port=${rule%/*}; protocol=${rule#*/}
        # Canonical decimal ports avoid leading-zero interpretation differences.
        if [[ "$port" == *:* ]]; then
            port="$((10#${port%:*})):$((10#${port#*:}))"
        else port="$((10#$port))"; fi
        printf 'pass in proto %s from any to self port %s keep state\n' "$protocol" "$port"
    done
}
write_pf_rules > "$candidate"
chmod 600 "$candidate"
# A custom ruleset can contain NAT, anchors and quick rules; automatic merging
# could silently change its meaning. Leave a concrete candidate for review.
if [[ -s "$config" ]] &&
   grep -Eq '^[[:space:]]*[^#[:space:]]' "$config" &&
   ! grep -Fxq '# Managed by CyberPatriot FreeBSD PF' "$config"; then
    log "FAILED existing unmanaged PF policy retained: $config. Review candidate $candidate and merge required rules with the existing policy before loading it."
    exit 1
fi
if ! kldstat -q -m pf; then
    # PF can be built into a kernel, in which case loading the module returns
    # an error even though pfctl is fully usable.
    kldload pf 2>/dev/null || pfctl -s info >/dev/null 2>&1 || {
        log 'FAILED: PF is unavailable in this kernel'; exit 1;
    }
fi
pf_info=$(pfctl -s info)
was_running=no
[[ "$pf_info" != *'Status: Enabled'* ]] || was_running=yes
if [[ "$was_running" == yes && ! -s "$config" ]]; then
    log "FAILED PF is active without a restorable configuration: $config. Running policy retained; candidate: $candidate"
    exit 1
fi
if ! pfctl -nf "$candidate"; then
    log "FAILED PF candidate validation: $candidate; running policy retained"
    exit 1
fi
existed=no
if [[ -e "$config" ]]; then
    existed=yes
    # A rollback must itself be loadable before touching the running policy.
    pfctl -nf "$config"
    backup_config "$config"
    backup=$CONFIG_BACKUP
fi
was_enabled=$(sysrc -n pf_enable 2>/dev/null || true)
was_enabled=${was_enabled:-NO}
rollback_pf() {
    local status=0
    if [[ "$existed" == yes ]]; then
        restore_config "$config" "$backup" || status=1
        pfctl -f "$config" || status=1
    else
        audit_file_change "$config" rm -f "$config" || status=1
    fi
    if [[ "$was_running" == no ]]; then pfctl -d || status=1; fi
    set_rc_value "pf_enable=$was_enabled" || status=1
    return "$status"
}
activate_pf() {
    audit_file_change "$config" copy_config_contents "$candidate" "$config" || return 1
    secure_path "$config" 600 || return 1
    # Do not use service pf start/restart: it flushes existing states.
    pfctl -f "$config" || return 1
    if [[ "$was_running" == no ]]; then pfctl -e || return 1; fi
    set_rc_value pf_enable=YES || return 1
    local info
    info=$(pfctl -s info) || return 1
    [[ "$info" == *'Status: Enabled'* ]] || return 1
    [[ "$(sysrc -n pf_enable)" == YES ]] || return 1
}
if ! activate_pf; then
    rollback_pf || log 'FAILED restoring PF state; use the saved configuration from the console'
    log "FAILED enabling PF; rollback attempted. Candidate retained: $candidate"
    exit 1
fi
rm -f "$candidate"
log "VERIFIED native PF active with boot configuration $config; existing connection states retained"
log "PF incoming application ports: ${rules[*]:-(none)}"
