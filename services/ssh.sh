#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/service_common.sh"
service_init
install_packages openssh-server
config=/etc/ssh/sshd_config
backup_config "$config"
backup=$CONFIG_BACKUP
configure_ssh() {
    local temp
    temp=$(mktemp) || return 1
    # First values win; put global settings before Includes and Match blocks.
    {
        printf '%s\n' '# BEGIN CyberPatriot SSH' 'PermitRootLogin no' \
            'PermitEmptyPasswords no' 'MaxAuthTries 3' '# END CyberPatriot SSH'
        sed '/^# BEGIN CyberPatriot SSH$/,/^# END CyberPatriot SSH$/d' "$config"
    } > "$temp" || { rm -f "$temp"; return 1; }
    cat "$temp" > "$config" || { rm -f "$temp"; return 1; }
    rm -f "$temp"
}
audit_file_change "$config" configure_ssh
secure_service_permissions ssh
install -d -m 755 /run/sshd
if ! /usr/sbin/sshd -t; then
    restore_config "$config" "$backup"
    log 'FAILED SSH validation; previous configuration restored'
    exit 1
fi
if ! enable_service ssh; then
    restore_config "$config" "$backup"
    refresh_service ssh || log "PENDING: restored configuration could not be reloaded"
    log 'FAILED starting SSH; previous configuration restored'
    exit 1
fi
log "SSH effective global settings: $(/usr/sbin/sshd -T | awk '$1 ~ /^(port|permitrootlogin|permitemptypasswords|maxauthtries)$/')"
log 'Existing ports, authentication methods, keys and Match policies retained; review scenario-specific Match overrides'
