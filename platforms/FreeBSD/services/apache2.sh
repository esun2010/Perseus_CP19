#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/service_common.sh"
service_init
install_packages apache24
require_commands apachectl
profiles=$(sysrc -n apache24_profiles 2>/dev/null || true)
flags=$(sysrc -n apache24_flags 2>/dev/null || true)
if [[ -n "$profiles" || "$flags" =~ (^|[[:space:]])-f ]]; then
    log 'FAILED: Apache profiles/custom -f configurations need their own hardening include; default configuration left unchanged'
    exit 1
fi
main=/usr/local/etc/apache24/httpd.conf
config=/usr/local/etc/apache24/extra/zz-cyberpatriot.conf
[[ ! -L "$config" ]] || { log "FAILED symbolic-link configuration: $config"; exit 1; }
backup_config "$main"
main_backup=$CONFIG_BACKUP
existed=no
if [[ -e "$config" ]]; then
    existed=yes
    backup_config "$config"
    backup=$CONFIG_BACKUP
fi
capture_service_state apache24
configure_apache_include() {
    local temp
    temp=$(mktemp) || return 1
    awk '/^# BEGIN CyberPatriot Apache$/ {managed=1} !managed {print} /^# END CyberPatriot Apache$/ {managed=0}' "$main" > "$temp" || { rm -f "$temp"; return 1; }
    printf '%s\n' '# BEGIN CyberPatriot Apache' "Include \"$config\"" '# END CyberPatriot Apache' >> "$temp" || { rm -f "$temp"; return 1; }
    cat "$temp" > "$main" || { rm -f "$temp"; return 1; }
    rm -f "$temp"
}
configure_apache() {
    printf '%s\n' 'ServerTokens Prod' 'ServerSignature Off' 'TraceEnable Off' > "$config"
}
rollback_apache() {
    restore_config "$main" "$main_backup" || return 1
    if [[ "$existed" == yes ]]; then restore_config "$config" "$backup"
    else audit_file_change "$config" rm -f "$config"; fi
}
if ! audit_file_change "$config" configure_apache ||
   ! audit_file_change "$main" configure_apache_include ||
   ! secure_service_permissions apache24 ||
   ! apachectl configtest ||
   ! service apache24 oneconfigtest; then
    rollback_apache
    log 'FAILED Apache validation; previous configuration restored'
    exit 1
fi
if ! enable_service apache24; then
    rollback_apache
    restore_service_state apache24 "$SERVICE_WAS_ENABLED" "$SERVICE_WAS_RUNNING" || log 'FAILED restoring Apache service state; inspect service apache24 status'
    log 'FAILED starting Apache; previous configuration restored'
    exit 1
fi
log 'Apache24 configured; existing sites, document roots, listeners and TLS settings retained'
