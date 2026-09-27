#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/service_common.sh"
service_init
# OpenSSH is part of the FreeBSD base system.
require_commands sshd ssh-keygen
flags=$(sysrc -n sshd_flags 2>/dev/null || true)
if [[ "$flags" =~ (^|[[:space:]])-f ]]; then
    log 'FAILED: sshd_flags selects a custom configuration; harden that configuration separately'
    exit 1
fi
config=/etc/ssh/sshd_config
backup_config "$config"
backup=$CONFIG_BACKUP
capture_service_state sshd
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
# The rc keygen action creates only missing host keys, honoring rc.conf policy.
service sshd onekeygen
if ! audit_file_change "$config" configure_ssh ||
   ! secure_service_permissions ssh ||
   ! /usr/sbin/sshd -t -f "$config" ||
   ! service sshd oneconfigtest; then
    restore_config "$config" "$backup"
    log 'FAILED SSH validation; previous configuration restored'
    exit 1
fi
if ! enable_service sshd; then
    restore_config "$config" "$backup"
    restore_service_state sshd "$SERVICE_WAS_ENABLED" "$SERVICE_WAS_RUNNING" || log 'FAILED restoring sshd service state; inspect service sshd status'
    log 'FAILED starting SSH; previous configuration restored'
    exit 1
fi
log "SSH effective global settings: $(/usr/sbin/sshd -T | awk '$1 ~ /^(port|permitrootlogin|permitemptypasswords|maxauthtries)$/')"
log 'Existing ports, authentication methods, keys and Match policies retained; review scenario-specific Match overrides'
